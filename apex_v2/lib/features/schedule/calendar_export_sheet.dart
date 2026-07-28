import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/calendar_export.dart';

/// Share / copy ICS + optional first Google Calendar link.
Future<void> showCalendarExportSheet(
  BuildContext context, {
  required String title,
  required List<CalendarShift> shifts,
}) async {
  if (shifts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No shifts to add.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  final ics = CalendarExport.toIcs(calendarName: title, shifts: shifts);
  final filename =
      'apex_${DateTime.now().millisecondsSinceEpoch}.ics';

  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                '${shifts.length} shift${shifts.length == 1 ? '' : 's'} — copy the calendar file into Google, Apple, or Outlook.',
                style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(ctx)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: ics));
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Copied $filename — paste into a .ics file or import.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy .ics'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  final uri = CalendarExport.googleTemplateUrl(shifts.first);
                  final ok = await launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                  );
                  if (!ok && ctx.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not open Google Calendar.'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.event_rounded),
                label: Text(
                  shifts.length == 1
                      ? 'Open in Google Calendar'
                      : 'Open first shift in Google Calendar',
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
