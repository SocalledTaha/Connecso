import 'package:flutter/foundation.dart';

@immutable
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.supportsSystemTunnel,
    required this.supportsPerAppRouting,
    required this.supportsBackgroundRefresh,
    required this.supportsCameraQr,
    required this.supportsImageQr,
    required this.supportedCores,
  });

  final bool supportsSystemTunnel;
  final bool supportsPerAppRouting;
  final bool supportsBackgroundRefresh;
  final bool supportsCameraQr;
  final bool supportsImageQr;
  final Set<String> supportedCores;

  static const android = PlatformCapabilities(
    supportsSystemTunnel: true,
    supportsPerAppRouting: true,
    supportsBackgroundRefresh: true,
    supportsCameraQr: true,
    supportsImageQr: true,
    // Advertise only cores that are actually packaged and end-to-end tested.
    supportedCores: {},
  );

  static const unsupported = PlatformCapabilities(
    supportsSystemTunnel: false,
    supportsPerAppRouting: false,
    supportsBackgroundRefresh: false,
    supportsCameraQr: false,
    supportsImageQr: false,
    supportedCores: {},
  );
}
