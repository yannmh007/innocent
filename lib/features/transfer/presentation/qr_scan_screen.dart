import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// Full-screen QR scanner used by the Transfer "Receive" flow.
///
/// The sending phone shows a QR code encoding its share URL
/// (`http://host:port/<token>`). This screen scans that code and pops the
/// decoded string back to the caller, which then connects to it — so the
/// receiver no longer has to read and type the address by hand.
///
/// Camera permission is requested by the caller (via permission_handler)
/// before this screen is pushed.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  // Guard so a QR that fires multiple detections only pops once.
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw != null && raw.isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(AppStrings.of(context).scanSenderQr),
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(onDetect: _onDetect),

          // Viewfinder square to guide aiming.
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.accentBlue, width: 3),
              borderRadius: BorderRadius.circular(16),
            ),
          ),

          // Hint.
          Positioned(
            bottom: 64,
            left: 24,
            right: 24,
            child: Text(AppStrings.of(context).scanQrHint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                height: 1.4,
                shadows: [Shadow(color: Colors.black, blurRadius: 8)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
