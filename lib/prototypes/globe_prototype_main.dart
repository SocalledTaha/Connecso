import 'package:flutter/material.dart';

import 'responsive_globe.dart';

void main() {
  runApp(const _GlobePrototypeApp());
}

class _GlobePrototypeApp extends StatelessWidget {
  const _GlobePrototypeApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: ResponsiveGlobe(showDebugControls: true),
        ),
      );
}
