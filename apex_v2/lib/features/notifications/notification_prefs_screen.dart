import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';

/// Employee controls for push + SMS fallback (plan #6).
class NotificationPrefsScreen extends StatefulWidget {
  const NotificationPrefsScreen({
    super.key,
    required this.organizationId,
  });

  final String organizationId;

  @override
  State<NotificationPrefsScreen> createState() =>
      _NotificationPrefsScreenState();
}

class _NotificationPrefsScreenState extends State<NotificationPrefsScreen> {
  final _client = Supabase.instance.client;
  final _phone = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool _myShifts = true;
  bool _shiftChanges = true;
  bool _swaps = true;
  bool _teamMessages = false;
  bool _schedulePublished = true;
  bool _push = true;
  bool _smsFallback = true;

  String get _userId => DemoMode.enabled
      ? DemoMode.userId
      : (_client.auth.currentUser?.id ?? '');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<dynamic>([
        _client
            .from('profiles')
            .select('phone')
            .eq('id', _userId)
            .maybeSingle(),
        _client
            .from('notification_preferences')
            .select()
            .eq('user_id', _userId)
            .maybeSingle(),
      ]);
      if (!mounted) return;
      final profile = results[0] as Map<String, dynamic>?;
      final prefs = results[1] as Map<String, dynamic>?;
      _phone.text = profile?['phone'] as String? ?? '';
      if (prefs != null) {
        _myShifts = prefs['my_shifts'] as bool? ?? true;
        _shiftChanges = prefs['shift_changes'] as bool? ?? true;
        _swaps = prefs['swap_opportunities'] as bool? ?? true;
        _teamMessages = prefs['team_messages'] as bool? ?? false;
        _schedulePublished = prefs['schedule_published'] as bool? ?? true;
        _push = prefs['push_enabled'] as bool? ?? true;
        _smsFallback = prefs['sms_fallback'] as bool? ?? true;
      }
      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load settings.';
      });
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _client.from('profiles').update({
        'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      }).eq('id', _userId);

      await _client.from('notification_preferences').upsert({
        'user_id': _userId,
        'organization_id': widget.organizationId,
        'my_shifts': _myShifts,
        'shift_changes': _shiftChanges,
        'swap_opportunities': _swaps,
        'team_messages': _teamMessages,
        'schedule_published': _schedulePublished,
        'push_enabled': _push,
        'sms_fallback': _smsFallback,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Notification settings saved.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
    }

    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 20, 32),
          children: [
            Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Expanded(
                child: Text('Notifications',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 0, 12),
              child: Text(
                'Push first. If it does not land, we SMS you — if you turn that on.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
              ),
            ),
            SwitchListTile(
              title: const Text('Push notifications'),
              value: _push,
              onChanged: _busy ? null : (v) => setState(() => _push = v),
            ),
            SwitchListTile(
              title: const Text('SMS if push misses'),
              subtitle: const Text('Needs a phone number below'),
              value: _smsFallback,
              onChanged:
                  _busy ? null : (v) => setState(() => _smsFallback = v),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 0, 8),
              child: TextField(
                controller: _phone,
                enabled: !_busy,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Mobile number',
                  hintText: '+1…',
                  filled: true,
                  fillColor: cs.surfaceContainer,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 0, 8),
              child: Text('Alert me about',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            SwitchListTile(
              title: const Text('My shifts'),
              value: _myShifts,
              onChanged: _busy ? null : (v) => setState(() => _myShifts = v),
            ),
            SwitchListTile(
              title: const Text('Shift changes'),
              value: _shiftChanges,
              onChanged:
                  _busy ? null : (v) => setState(() => _shiftChanges = v),
            ),
            SwitchListTile(
              title: const Text('Swap opportunities'),
              value: _swaps,
              onChanged: _busy ? null : (v) => setState(() => _swaps = v),
            ),
            SwitchListTile(
              title: const Text('Team messages'),
              value: _teamMessages,
              onChanged:
                  _busy ? null : (v) => setState(() => _teamMessages = v),
            ),
            SwitchListTile(
              title: const Text('Schedule published'),
              value: _schedulePublished,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _schedulePublished = v),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: Text(_busy ? 'Saving…' : 'Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
