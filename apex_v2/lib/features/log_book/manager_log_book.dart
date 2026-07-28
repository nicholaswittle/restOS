import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Manager log book — handoff notes for the next crew.
///
/// Owner / manager / server can write; everyone else is read-only.
class ManagerLogBook extends StatefulWidget {
  const ManagerLogBook({
    super.key,
    required this.organizationId,
    this.canWrite,
  });

  final String organizationId;

  /// When null, derived from the signed-in profile role.
  final bool? canWrite;

  @override
  State<ManagerLogBook> createState() => _ManagerLogBookState();
}

class _ManagerLogBookState extends State<ManagerLogBook> {
  final _client = Supabase.instance.client;
  final _noteController = TextEditingController();

  bool _loading = true;
  String? _error;
  bool _saving = false;
  bool _composing = false;
  String? _expandedId;

  _ProfileData? _profile;
  List<_ShiftNoteData> _notes = const [];
  DateTime _shiftDate = DateTime.now();

  final _subs = <StreamSubscription<dynamic>>[];

  String get _userId => _client.auth.currentUser?.id ?? '';

  bool get _canWrite {
    if (widget.canWrite != null) return widget.canWrite!;
    return _profile?.canWriteNotes ?? false;
  }

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
    _noteController.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    _subs.add(
      _client
          .from('shift_notes')
          .stream(primaryKey: ['id'])
          .eq('organization_id', widget.organizationId)
          .listen((_) => _load()),
    );
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final results = await Future.wait<dynamic>([
        _client
            .from('profiles')
            .select('name, role, organization_id')
            .eq('id', _userId)
            .eq('organization_id', widget.organizationId)
            .single(),
        _client
            .from('shift_notes')
            .select(
              'id, organization_id, author_id, shift_date, note, photo_url, created_at, profiles(name)',
            )
            .eq('organization_id', widget.organizationId)
            .order('created_at', ascending: false)
            .limit(40),
      ]);

      if (!mounted) return;

      setState(() {
        _profile = _ProfileData.fromMap(results[0] as Map<String, dynamic>);
        _notes = (results[1] as List)
            .cast<Map<String, dynamic>>()
            .map(_ShiftNoteData.fromMap)
            .toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load shift notes. Pull to retry.';
        });
      }
    }
  }

  Future<void> _saveNote() async {
    if (_saving) return;
    final text = _noteController.text.trim();
    if (text.isEmpty) {
      _snack('Write a note before saving.');
      return;
    }

    setState(() => _saving = true);
    try {
      await _client.from('shift_notes').insert({
        'organization_id': widget.organizationId,
        'author_id': _userId,
        'shift_date': DateFormat('yyyy-MM-dd').format(_shiftDate),
        'note': text,
      });

      if (!mounted) return;
      _noteController.clear();
      setState(() {
        _saving = false;
        _composing = false;
        _shiftDate = DateTime.now();
      });
      _snack('Note saved for the next crew.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Could not save note. Try again.');
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _shiftDate,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) {
      setState(() => _shiftDate = picked);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
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
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Log Book',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _canWrite
                            ? 'Handoff notes for the next crew'
                            : 'Notes from managers and previous shifts',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.75),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              sliver: SliverList.list(children: [
                if (_canWrite) ...[
                  if (!_composing)
                    _ActionButton(
                      icon: Icons.edit_note_rounded,
                      label: 'Add Note',
                      onTap: () => setState(() => _composing = true),
                    )
                  else
                    _ComposeCard(
                      controller: _noteController,
                      shiftDate: _shiftDate,
                      saving: _saving,
                      onPickDate: _pickDate,
                      onCancel: () => setState(() {
                        _composing = false;
                        _noteController.clear();
                      }),
                      onSave: _saveNote,
                    ),
                  const SizedBox(height: 12),
                ],
                if (_notes.isEmpty)
                  const _EmptyCard(
                    icon: Icons.sticky_note_2_outlined,
                    title: 'No shift notes yet',
                    subtitle:
                        'Handoff notes from the previous crew will appear here.',
                  )
                else
                  for (var i = 0; i < _notes.length; i++) ...[
                    _NoteTile(
                      note: _notes[i],
                      expanded: _expandedId == _notes[i].id,
                      onTap: () => setState(() {
                        _expandedId =
                            _expandedId == _notes[i].id ? null : _notes[i].id;
                      }),
                    ),
                    if (i != _notes.length - 1) const SizedBox(height: 12),
                  ],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Pure helpers ────────────────────────────────────────────────────────────

String _formatDayLabel(String dateKey) {
  final d = DateTime.tryParse(dateKey);
  if (d == null) return dateKey;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(d.year, d.month, d.day);
  final diff = target.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == -1) return 'Yesterday';
  if (diff == 1) return 'Tomorrow';
  return DateFormat('EEE, MMM d').format(d);
}

String _relativeTime(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return DateFormat('MMM d').format(t);
}

// ─── Typed models ────────────────────────────────────────────────────────────

class _ProfileData {
  const _ProfileData({
    required this.name,
    required this.role,
    required this.organizationId,
  });

  final String name;
  final String role;
  final String organizationId;

  bool get canWriteNotes {
    final r = role.toLowerCase();
    return r == 'owner' || r == 'manager' || r == 'server';
  }

  factory _ProfileData.fromMap(Map<String, dynamic> m) => _ProfileData(
        name: m['name'] as String? ?? 'there',
        role: m['role'] as String? ?? 'Staff',
        organizationId: m['organization_id'] as String? ?? '',
      );
}

class _ShiftNoteData {
  const _ShiftNoteData({
    required this.id,
    required this.note,
    required this.shiftDate,
    required this.author,
    required this.createdAt,
    this.photoUrl,
  });

  final String id;
  final String note;
  final String shiftDate;
  final String author;
  final DateTime createdAt;
  final String? photoUrl;

  factory _ShiftNoteData.fromMap(Map<String, dynamic> m) => _ShiftNoteData(
        id: m['id'] as String? ?? '',
        note: m['note'] as String? ?? '',
        shiftDate: m['shift_date'] as String? ?? '',
        author: (m['profiles'] as Map?)?['name'] as String? ?? 'Teammate',
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
        photoUrl: m['photo_url'] as String?,
      );
}

// ─── UI pieces ───────────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _SkeletonBox(width: 160, height: 34, color: cs.surfaceContainerHigh),
          const SizedBox(height: 8),
          _SkeletonBox(width: 220, height: 18, color: cs.surfaceContainerHigh),
          const SizedBox(height: 24),
          _SkeletonBox(
              width: double.infinity, height: 88, color: cs.surfaceContainerHigh),
          const SizedBox(height: 12),
          _SkeletonBox(
              width: double.infinity, height: 88, color: cs.surfaceContainerHigh),
          const SizedBox(height: 12),
          _SkeletonBox(
              width: double.infinity, height: 88, color: cs.surfaceContainerHigh),
        ]),
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
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
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
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.8)),
          ),
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

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(children: [
            Icon(icon, color: cs.primary, size: 26),
            const SizedBox(height: 6),
            Text(label, style: Theme.of(context).textTheme.labelLarge),
          ]),
        ),
      ),
    );
  }
}

class _ComposeCard extends StatelessWidget {
  const _ComposeCard({
    required this.controller,
    required this.shiftDate,
    required this.saving,
    required this.onPickDate,
    required this.onCancel,
    required this.onSave,
  });

  final TextEditingController controller;
  final DateTime shiftDate;
  final bool saving;
  final VoidCallback onPickDate;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'New handoff note',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: cs.onPrimaryContainer),
          ),
          const SizedBox(height: 12),
          Material(
            color: cs.onPrimaryContainer.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onPickDate,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Icon(Icons.calendar_today_rounded,
                      size: 18, color: cs.onPrimaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      DateFormat('EEE, MMM d').format(shiftDate),
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: cs.onPrimaryContainer),
                    ),
                  ),
                  Icon(Icons.expand_more_rounded,
                      color: cs.onPrimaryContainer.withValues(alpha: 0.6)),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: 4,
            minLines: 3,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(color: cs.onPrimaryContainer),
            decoration: InputDecoration(
              hintText: 'Walk-in fridge down, called repair…',
              hintStyle: TextStyle(
                color: cs.onPrimaryContainer.withValues(alpha: 0.45),
              ),
              filled: true,
              fillColor: cs.onPrimaryContainer.withValues(alpha: 0.08),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            TextButton(
              onPressed: saving ? null : onCancel,
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                ),
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                backgroundColor: cs.primary,
              ),
              onPressed: saving ? null : onSave,
              icon: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Icon(Icons.check_rounded),
              label: const Text(
                'Save',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({
    required this.note,
    required this.expanded,
    required this.onTap,
  });

  final _ShiftNoteData note;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.sticky_note_2_rounded,
                  color: cs.primary, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${note.author} · ${_formatDayLabel(note.shiftDate)}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    note.note,
                    maxLines: expanded ? null : 2,
                    overflow:
                        expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text(
                      _relativeTime(note.createdAt),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.45),
                          ),
                    ),
                    const Spacer(),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: cs.onSurface.withValues(alpha: 0.4),
                    ),
                  ]),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon,
                color: cs.onSurface.withValues(alpha: 0.5), size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
