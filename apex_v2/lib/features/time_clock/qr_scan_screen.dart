import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/clock_qr.dart';

/// Employee scans the kitchen wall QR (or types today's short code).
///
/// On a valid read, pops `true` so the caller can clock in/out.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({
    super.key,
    required this.organizationId,
    this.clockingOut = false,
  });

  final String organizationId;
  final bool clockingOut;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _manual = TextEditingController();
  final _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  bool _handled = false;
  bool _manualMode = false;
  String? _error;

  @override
  void dispose() {
    _manual.dispose();
    _scanner.dispose();
    super.dispose();
  }

  void _accept(String raw) {
    if (_handled) return;
    if (!ClockQr.accepts(raw, widget.organizationId)) {
      setState(() => _error = 'Wrong code for today. Check the wall QR.');
      return;
    }
    _handled = true;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = widget.clockingOut ? 'Scan to clock out' : 'Scan to clock in';

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
            child: Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close_rounded),
              ),
              Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _manualMode = !_manualMode;
                  _error = null;
                }),
                child: Text(_manualMode ? 'Camera' : 'Type code'),
              ),
            ]),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(_error!,
                  style: TextStyle(color: cs.error),
                  textAlign: TextAlign.center),
            ),
          Expanded(
            child: _manualMode ? _manualBody(cs) : _cameraBody(cs),
          ),
        ]),
      ),
    );
  }

  Widget _cameraBody(ColorScheme cs) {
    return Stack(children: [
      MobileScanner(
        controller: _scanner,
        onDetect: (capture) {
          final raw = capture.barcodes
              .map((b) => b.rawValue)
              .whereType<String>()
              .firstOrNull;
          if (raw != null) _accept(raw);
        },
      ),
      Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Point at the kitchen wall QR',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  shadows: const [Shadow(blurRadius: 8, color: Colors.black)],
                ),
          ),
        ),
      ),
    ]);
  }

  Widget _manualBody(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the 6-character code under the wall QR.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _manual,
            textCapitalization: TextCapitalization.characters,
            autofocus: true,
            maxLength: 6,
            decoration: InputDecoration(
              labelText: 'Short code',
              filled: true,
              fillColor: cs.surfaceContainer,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: _accept,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => _accept(_manual.text),
            child: Text(widget.clockingOut ? 'Clock out' : 'Clock in'),
          ),
        ],
      ),
    );
  }
}
