import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';
import '../../core/labor_guardrails.dart';
import '../../core/schedule_text_parser.dart';
import '../../core/shift_time.dart';

/// Photo / text → review → publish (plan #8).
///
/// Privacy path: prefer pasted/OCR text + local parser. Optional cloud vision
/// when `parse-schedule` has ANTHROPIC_API_KEY.
class PhotoImportScreen extends StatefulWidget {
  const PhotoImportScreen({
    super.key,
    required this.organizationId,
  });

  final String organizationId;

  @override
  State<PhotoImportScreen> createState() => _PhotoImportScreenState();
}

class _PhotoImportScreenState extends State<PhotoImportScreen> {
  final _client = Supabase.instance.client;
  final _text = TextEditingController();
  final _picker = ImagePicker();

  XFile? _image;
  List<int>? _imageBytes;
  String? _mediaType;

  bool _parsing = false;
  bool _publishing = false;
  String? _status;
  List<ParsedShift> _rows = [];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _pick({required ImageSource source}) async {
    final file = await _picker.pickImage(
      source: source,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      _image = file;
      _imageBytes = bytes;
      _mediaType = file.mimeType ?? 'image/jpeg';
      _status = 'Photo ready — paste any OCR text below, then Parse.';
    });
  }

  Future<void> _parse() async {
    if (_parsing) return;
    setState(() {
      _parsing = true;
      _status = null;
      _rows = [];
    });

    try {
      // 1) Always try local deterministic parse on text first.
      final local = ScheduleTextParser().parse(_text.text);
      if (local.isNotEmpty) {
        setState(() {
          _rows = local;
          _parsing = false;
          _status = 'Parsed ${local.length} shift${local.length == 1 ? '' : 's'} on-device.';
        });
        return;
      }

      if (DemoMode.enabled) {
        setState(() {
          _parsing = false;
          _status =
              'Demo: paste lines like "Sam Chen Tue 4-10" (no cloud parse).';
        });
        return;
      }

      // 2) Cloud structuring — text preferred; image only if present.
      final body = <String, dynamic>{
        'week_start': dateKeyOf(
          DateTime.now().subtract(Duration(days: DateTime.now().weekday - 1)),
        ),
      };
      if (_text.text.trim().isNotEmpty) {
        body['text'] = _text.text.trim();
      }
      if (_imageBytes != null && _imageBytes!.isNotEmpty) {
        body['image_base64'] = base64Encode(_imageBytes!);
        body['media_type'] = _mediaType ?? 'image/jpeg';
      }

      if (body['text'] == null && body['image_base64'] == null) {
        setState(() {
          _parsing = false;
          _status = 'Add a photo or paste schedule text first.';
        });
        return;
      }

      final res = await _client.functions.invoke('parse-schedule', body: body);
      final data = res.data;
      if (data is Map && data['error'] != null) {
        setState(() {
          _parsing = false;
          _status = data['message'] as String? ??
              data['error'].toString();
        });
        return;
      }

      final list = (data is Map ? data['shifts'] : null) as List? ?? const [];
      final parsed = list
          .cast<Map<String, dynamic>>()
          .map(ParsedShift.fromJson)
          .where((s) => s.staff.isNotEmpty && s.shiftDate.isNotEmpty)
          .toList();

      setState(() {
        _rows = parsed;
        _parsing = false;
        _status = parsed.isEmpty
            ? 'Nothing clear in that photo — try typing the names and times.'
            : 'Review ${parsed.length} shift${parsed.length == 1 ? '' : 's'}, then publish.';
      });
    } catch (e) {
      debugPrint('parse-schedule failed: $e');
      if (!mounted) return;
      setState(() {
        _parsing = false;
        _status =
            'Cloud parse unavailable. Paste lines like "Mike Tue 4-10" and Parse again.';
      });
    }
  }

  Future<void> _publish() async {
    if (_publishing || _rows.isEmpty) return;
    setState(() => _publishing = true);
    try {
      final byStaff = <String, List<ParsedShift>>{};
      for (final s in _rows) {
        byStaff.putIfAbsent(s.staff, () => []).add(s);
      }
      final warnings = <String>[];
      for (final entry in byStaff.entries) {
        final sample = entry.value.first;
        final w = await LaborGuardrails(_client).checkProposedShifts(
          organizationId: widget.organizationId,
          staff: entry.key,
          shiftDates: entry.value.map((s) => s.shiftDate).toList(),
          startTime: sample.startTime,
          endTime: sample.endTime,
        );
        warnings.addAll(w);
      }
      if (!mounted) return;
      if (warnings.isNotEmpty) {
        setState(() => _publishing = false);
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Labor checks'),
            content: SingleChildScrollView(
              child: Text(warnings.join('\n\n')),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
        if (!mounted) return;
        setState(() => _publishing = true);
      }

      final rows = [
        for (final s in _rows) s.toInsertRow(widget.organizationId),
      ];
      await _client.from('shifts').insert(rows);
      if (!mounted) return;
      _snack(
        'Published ${rows.length} shift${rows.length == 1 ? '' : 's'}.',
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _publishing = false);
      _snack('Could not publish. Check names match your team roster.');
    }
  }

  void _removeAt(int i) => setState(() => _rows.removeAt(i));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
            child: Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Expanded(
                child: Text('Import schedule',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
            ]),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Text(
                  'Photo the whiteboard or paste the text. Review before anything saves.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _parsing
                          ? null
                          : () => _pick(source: ImageSource.camera),
                      icon: const Icon(Icons.photo_camera_rounded),
                      label: const Text('Camera'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _parsing
                          ? null
                          : () => _pick(source: ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_rounded),
                      label: const Text('Gallery'),
                    ),
                  ),
                ]),
                if (_image != null) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 16 / 10,
                      child: Image.memory(
                        Uint8List.fromList(_imageBytes ?? const []),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: cs.surfaceContainerHigh,
                          alignment: Alignment.center,
                          child: const Text('Preview unavailable'),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _text,
                  minLines: 4,
                  maxLines: 8,
                  enabled: !_parsing && !_publishing,
                  decoration: InputDecoration(
                    labelText: 'Schedule text (preferred)',
                    hintText: 'Sam Chen Tue 4-10\nPriya Nair Fri Sat 5-11',
                    alignLabelWithHint: true,
                    filled: true,
                    fillColor: cs.surfaceContainer,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sending text keeps the photo on-device. Cloud vision is optional.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: _parsing || _publishing ? null : _parse,
                  icon: _parsing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.document_scanner_outlined),
                  label: Text(_parsing ? 'Parsing…' : 'Parse'),
                ),
                if (_status != null) ...[
                  const SizedBox(height: 12),
                  Text(_status!,
                      style: Theme.of(context).textTheme.bodyMedium),
                ],
                if (_rows.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('Review',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  for (var i = 0; i < _rows.length; i++) ...[
                    _ReviewTile(
                      shift: _rows[i],
                      onRemove: () => _removeAt(i),
                    ),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _publishing ? null : _publish,
                      child: _publishing
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : Text(
                              'Publish · ${_rows.length} shift${_rows.length == 1 ? '' : 's'}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.shift, required this.onRemove});

  final ParsedShift shift;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(shift.staff),
        subtitle: Text(
          '${formatDayLabel(shift.shiftDate)} · ${formatTime(shift.startTime)}–${formatTime(shift.endTime)}',
        ),
        trailing: IconButton(
          tooltip: 'Remove',
          onPressed: onRemove,
          icon: const Icon(Icons.close_rounded),
        ),
      ),
    );
  }
}
