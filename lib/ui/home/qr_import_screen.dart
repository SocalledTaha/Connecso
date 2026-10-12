import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/app_strings.dart';
import '../widgets/app_notice.dart';

class QrImportScreen extends StatefulWidget {
  const QrImportScreen({required this.strings, super.key});
  final AppStrings strings;

  @override
  State<QrImportScreen> createState() => _QrImportScreenState();
}

class _QrImportScreenState extends State<QrImportScreen> {
  late final MobileScannerController _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() { _scanner.dispose(); super.dispose(); }

  void _return(String? value) {
    if (_done || value == null || value.trim().isEmpty) return;
    _done = true;
    Navigator.of(context).pop(value.trim());
  }

  Future<void> _pickImage() async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null || !mounted) return;
    try {
      final capture = await _scanner.analyzeImage(image.path);
      if (capture == null) {
        if (mounted) AppNotice.show(context, widget.strings.scanFailed);
        return;
      }
      _return(capture.barcodes.firstOrNull?.rawValue);
      if (!_done && mounted) AppNotice.show(context, widget.strings.scanFailed);
    } catch (_) {
      if (mounted) AppNotice.show(context, widget.strings.scanFailed);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.strings.scanQr)),
        body: Stack(fit: StackFit.expand, children: [
          MobileScanner(controller: _scanner, onDetect: (capture) => _return(capture.barcodes.firstOrNull?.rawValue)),
          Center(child: Container(width: 250, height: 250, decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(24)))),
          PositionedDirectional(start: 18, end: 18, bottom: 24, child: FilledButton.icon(onPressed: _pickImage, icon: const Icon(Icons.image_outlined), label: Text(widget.strings.chooseImage))),
        ]),
      );
}
