import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';
import '../../core/entitlements.dart';
import '../../core/shift_time.dart';

/// Daily sidework checklist — ported from Apex v1 SideworkService / Section.
class SideworkScreen extends StatefulWidget {
  const SideworkScreen({
    super.key,
    required this.organizationId,
    this.role,
  });

  final String organizationId;
  final StaffRole? role;

  @override
  State<SideworkScreen> createState() => _SideworkScreenState();
}

class _SideworkScreenState extends State<SideworkScreen> {
  final _client = Supabase.instance.client;
  final _taskCtrl = TextEditingController();

  bool _loading = true;
  String? _error;
  bool _busy = false;

  String? _myName;
  List<String> _staffNames = const [];
  String? _assignee;
  List<_Task> _tasks = const [];
  late DateTime _day;

  final _subs = <StreamSubscription<dynamic>>[];

  bool get _canManage => widget.role?.canManage ?? false;

  String get _userId => DemoMode.enabled
      ? DemoMode.userId
      : (_client.auth.currentUser?.id ?? '');

  String get _dayKey => dateKeyOf(_day);

  @override
  void initState() {
    super.initState();
    _day = DateTime.now();
    _load().then((_) => _subscribeRealtime());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _taskCtrl.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    _subs.add(
      _client
          .from('sidework')
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
      final results = await Future.wait<dynamic>([
        _client
            .from('profiles')
            .select('name')
            .eq('id', _userId)
            .eq('organization_id', widget.organizationId)
            .maybeSingle(),
        _client
            .from('profiles')
            .select('name')
            .eq('organization_id', widget.organizationId)
            .order('name'),
        _client
            .from('sidework')
            .select(
              'id, task, assigned_to, completed, completed_at, task_date',
            )
            .eq('organization_id', widget.organizationId)
            .eq('task_date', _dayKey)
            .order('created_at'),
      ]);

      if (!mounted) return;
      final me = results[0] as Map<String, dynamic>?;
      final names = (results[1] as List)
          .cast<Map<String, dynamic>>()
          .map((r) => r['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
      var tasks = (results[2] as List)
          .cast<Map<String, dynamic>>()
          .map(_Task.fromMap)
          .toList();

      if (!_canManage && me != null) {
        final myName = me['name'] as String? ?? '';
        tasks = tasks.where((t) => t.assignedTo == myName).toList();
      }

      setState(() {
        _myName = me?['name'] as String?;
        _staffNames = names;
        _assignee ??= names.isNotEmpty ? names.first : _myName;
        _tasks = tasks;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load sidework. Pull to retry.';
      });
    }
  }

  void _shiftDay(int delta) {
    setState(() {
      _day = _day.add(Duration(days: delta));
    });
    _load();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _addTask() async {
    if (!_canManage || _busy) return;
    final task = _taskCtrl.text.trim();
    final assignee = _assignee;
    if (task.isEmpty || assignee == null || assignee.isEmpty) {
      _snack('Add a task and pick who owns it.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _client.from('sidework').insert({
        'organization_id': widget.organizationId,
        'task_date': _dayKey,
        'day_num': _day.day,
        'task': task,
        'assigned_to': assignee,
      });
      if (!mounted) return;
      _taskCtrl.clear();
      setState(() => _busy = false);
      _snack('Added.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not add task.');
    }
  }

  Future<void> _toggle(_Task task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final next = !task.completed;
      await _client.from('sidework').update({
        'completed': next,
        'completed_at': next ? DateTime.now().toIso8601String() : null,
        'completed_by': next ? _userId : null,
      }).eq('id', task.id);
      if (!mounted) return;
      setState(() => _busy = false);
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not update.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _tasks.isEmpty && _error == null) {
      return const Scaffold(body: _LoadingView());
    }
    if (_error != null && _tasks.isEmpty) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final cs = Theme.of(context).colorScheme;
    final done = _tasks.where((t) => t.completed).length;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => _load(),
        color: cs.primary,
        backgroundColor: cs.surfaceContainer,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        IconButton(
                          onPressed: () =>
                              Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Sidework',
                                  style: Theme.of(context)
                                      .textTheme
                                      .displaySmall),
                              Text(
                                _canManage
                                    ? 'Assign closing / opening tasks'
                                    : 'Your checklist for the day',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: cs.onSurface
                                          .withValues(alpha: 0.55),
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ]),
                      Row(children: [
                        IconButton(
                          onPressed: () => _shiftDay(-1),
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        Expanded(
                          child: Text(
                            formatDayLabel(_dayKey),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          onPressed: () => _shiftDay(1),
                          icon: const Icon(Icons.chevron_right_rounded),
                        ),
                      ]),
                      if (_tasks.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            '$done of ${_tasks.length} done',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color:
                                      cs.onSurface.withValues(alpha: 0.55),
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              sliver: SliverList.list(children: [
                if (_canManage) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _taskCtrl,
                            enabled: !_busy,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              labelText: 'Task',
                              hintText: 'Restock ice, wipe bar, …',
                              filled: true,
                              fillColor: cs.surfaceContainerHigh,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onSubmitted: (_) => _addTask(),
                          ),
                          const SizedBox(height: 10),
                          if (_staffNames.isNotEmpty)
                            DropdownButtonFormField<String>(
                              key: ValueKey(_assignee),
                              initialValue: _assignee,
                              items: [
                                for (final n in _staffNames)
                                  DropdownMenuItem(
                                      value: n, child: Text(n)),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() => _assignee = v),
                              decoration: const InputDecoration(
                                labelText: 'Assign to',
                              ),
                            ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _busy ? null : _addTask,
                            child: const Text('Add task'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_tasks.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _canManage
                            ? 'No tasks for this day yet.'
                            : 'Nothing assigned to you today.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                      ),
                    ),
                  )
                else
                  for (final t in _tasks) ...[
                    _TaskTile(
                      task: t,
                      showAssignee: _canManage,
                      onToggle: _busy ? null : () => _toggle(t),
                    ),
                    const SizedBox(height: 8),
                  ],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Task {
  const _Task({
    required this.id,
    required this.task,
    required this.assignedTo,
    required this.completed,
  });

  final String id;
  final String task;
  final String assignedTo;
  final bool completed;

  factory _Task.fromMap(Map<String, dynamic> m) => _Task(
        id: m['id'] as String? ?? '',
        task: m['task'] as String? ?? '',
        assignedTo: m['assigned_to'] as String? ?? '',
        completed: m['completed'] as bool? ?? false,
      );
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.showAssignee,
    this.onToggle,
  });

  final _Task task;
  final bool showAssignee;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: CheckboxListTile(
        value: task.completed,
        onChanged: onToggle == null ? null : (_) => onToggle!(),
        title: Text(
          task.task,
          style: TextStyle(
            decoration:
                task.completed ? TextDecoration.lineThrough : null,
            color: task.completed
                ? cs.onSurface.withValues(alpha: 0.45)
                : null,
          ),
        ),
        subtitle: showAssignee ? Text(task.assignedTo) : null,
        controlAffinity: ListTileControlAffinity.leading,
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
        child: Container(
          height: 200,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
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
