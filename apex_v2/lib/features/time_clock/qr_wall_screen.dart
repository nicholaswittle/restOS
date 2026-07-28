import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/clock_qr.dart';
import '../../core/shift_time.dart';

/// Manager wall display: today's rotating clock-in QR.
///
/// Put this on a kitchen tablet or print it. Code dies at midnight
/// (yesterday still accepted for late closes).
class QrWallScreen extends StatelessWidget {
  const QrWallScreen({super.key, required this.organizationId});

  final String organizationId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final payload = ClockQr.payloadFor(organizationId);
    final short = ClockQr.shortCode(organizationId);
    final day = formatDayLabel(dateKeyOf(DateTime.now()));

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text('Clock-in QR',
                      style: Theme.of(context).textTheme.headlineSmall),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                'Hang this by the door. Staff scan to clock in — rotates daily.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(day,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: QrImageView(
                          data: payload,
                          version: QrVersions.auto,
                          size: 240,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Code · $short',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                              fontFamily: 'monospace',
                              letterSpacing: 3,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Works if the camera fails — type this instead',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.5),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: short));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Copied $short'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy short code'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
