import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/l10n.dart';
import '../core/theme.dart';

/// Full-screen camera scanner. Returns the first barcode / QR value it reads (or null).
/// The camera permission is asked the first time it opens.
Future<String?> scanBarcode(BuildContext context) =>
    Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _ScannerPage()));

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();
  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v != null && v.isNotEmpty) {
        _done = true;
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    final size = MediaQuery.sizeOf(context);
    final box = Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.42), width: size.width * 0.78, height: size.width * 0.5);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(ar ? 'امسح الباركود' : 'Scan barcode'),
        actions: [
          IconButton(tooltip: ar ? 'الفلاش' : 'Torch', icon: const Icon(Icons.flash_on_rounded), onPressed: () => _controller.toggleTorch()),
          IconButton(tooltip: ar ? 'لف الكاميرا' : 'Switch camera', icon: const Icon(Icons.cameraswitch_rounded), onPressed: () => _controller.switchCamera()),
        ],
      ),
      body: Stack(children: [
        Positioned.fill(
          child: MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.no_photography_rounded, color: Colors.white70, size: 56),
                  const SizedBox(height: 16),
                  Text(
                    error.errorCode == MobileScannerErrorCode.permissionDenied
                        ? (ar ? 'محتاجين إذن الكاميرا علشان نمسح الباركود. فعّله من إعدادات الموبايل.' : 'Camera permission is needed. Enable it in the phone settings.')
                        : (ar ? 'الكاميرا مش شغالة دلوقتي.' : 'The camera is not available.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, height: 1.6),
                  ),
                ]),
              ),
            ),
          ),
        ),
        // dim everything except the scan window
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _WindowPainter(box)),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          top: box.bottom + 24,
          child: Text(ar ? 'وجّه الكاميرا على الباركود وهيتقري لوحده' : 'Point the camera at the barcode — it reads automatically',
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
        ),
      ]),
    );
  }
}

class _WindowPainter extends CustomPainter {
  _WindowPainter(this.box);
  final Rect box;
  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(box, const Radius.circular(18));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(r)),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawRRect(r, Paint()
      ..color = BrandColors.electric
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(_WindowPainter old) => old.box != box;
}
