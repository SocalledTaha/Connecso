import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/models/vpn_node.dart';
import '../../domain/services/connection_manager.dart';
import '../../domain/services/core_manager.dart';
import '../../domain/services/split_tunnel_policy.dart';
import '../../domain/services/location_resolver.dart';
import '../../domain/services/xray_config_builder.dart';
import '../../data/repositories/subscription_repository.dart';

class AndroidVpnAdapter implements TunnelAdapter {
  static const _channel = MethodChannel('com.connecso.client/vpn');
  static const _debugTunnelEngine = String.fromEnvironment(
    'CONNECSO_TUNNEL_ENGINE',
    defaultValue: 'AUTO',
  );
  final Map<String, Future<Uint8List?>> _applicationIconCache = {};
  bool fakeDnsEnabled = false;
  bool _startWasDataplaneVerified = false;
  VoidCallback? _externalStateChanged;
  void Function(Map<Object?, Object?>)? _androidUpdateProgressHandler;
  void Function(String, Duration?)? _destinationPingProgressHandler;

  void setAndroidUpdateProgressHandler(
    void Function(Map<Object?, Object?>)? handler,
  ) {
    _androidUpdateProgressHandler = handler;
  }

  void setExternalStateChangedHandler(VoidCallback handler) {
    _externalStateChanged = handler;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'vpnStateChanged') {
        _externalStateChanged?.call();
      } else if (call.method == 'androidUpdateProgress' &&
          call.arguments is Map) {
        _androidUpdateProgressHandler?.call(
          Map<Object?, Object?>.from(call.arguments as Map),
        );
      } else if (call.method == 'destinationPingProgress' &&
          call.arguments is Map) {
        final event = Map<Object?, Object?>.from(call.arguments as Map);
        final nodeId = event['nodeId'];
        final latencyMs = event['latencyMs'];
        if (nodeId is String && nodeId.isNotEmpty) {
          _destinationPingProgressHandler?.call(
            nodeId,
            event['success'] == true && latencyMs is num && latencyMs > 0
                ? Duration(milliseconds: latencyMs.toInt())
                : null,
          );
        }
      }
    });
  }

  void setDestinationPingProgressHandler(
    void Function(String nodeId, Duration? latency)? handler,
  ) {
    _destinationPingProgressHandler = handler;
  }

  @override
  Future<void> requestPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('prepareVpn') ?? false;
      if (!granted) {
        throw const CoreException('VPN permission was not granted.');
      }
    } on MissingPluginException {
      throw const CoreException('Android VPN adapter is unavailable.');
    } on PlatformException catch (error) {
      throw CoreException(error.message ?? 'VPN permission failed.');
    }
  }

  Future<List<Map<String, Object?>>> installedApplications() async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'installedApplications',
    );
    return rows
            ?.map(
              (row) => row.map((key, value) => MapEntry(key.toString(), value)),
            )
            .toList() ??
        const [];
  }

  Future<Uint8List?> applicationIcon(String packageName) =>
      _applicationIconCache.putIfAbsent(packageName, () async {
        try {
          return await _channel.invokeMethod<Uint8List>('applicationIcon', {
            'packageName': packageName,
          });
        } on PlatformException {
          return null;
        }
      });

  Future<void> initializeCore() async {
    try {
      final available =
          await _channel.invokeMethod<bool>('coreAvailable') ?? false;
      if (!available) {
        throw const CoreException('Xray runtime is not available.');
      }
    } on PlatformException catch (error) {
      throw CoreException(error.message ?? 'VPN core initialization failed.');
    }
  }

  Future<String?> activeQuickTileNodeId() async {
    final state = await _channel.invokeMapMethod<Object?, Object?>(
      'quickTileConnection',
    );
    if (state?['active'] != true) return null;
    final nodeId = state?['nodeId'];
    return nodeId is String && nodeId.isNotEmpty ? nodeId : null;
  }

  Future<Map<Object?, Object?>> quickTileConnection() async {
    return await _channel.invokeMapMethod<Object?, Object?>(
          'quickTileConnection',
        ) ??
        const {};
  }

  Future<bool> requestAddQuickSettingsTile() async =>
      await _channel.invokeMethod<bool>('requestAddQuickSettingsTile') ?? false;

  Future<bool> requestAddHomeScreenWidget() async =>
      await _channel.invokeMethod<bool>('requestAddHomeScreenWidget') ?? false;

  Future<Map<Object?, Object?>> runSpeedTest() async =>
      await _channel.invokeMapMethod<Object?, Object?>('speedTest') ?? const {};

  Future<void> updateWidgetData(Map<String, Object?> data) =>
      _channel.invokeMethod<void>('updateWidgetData', data);

  @override
  Future<void> start(
    ProxyCore core,
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  }) async {
    _startWasDataplaneVerified = false;
    try {
      final resolvedLocation = const LocationResolver().resolve(node);
      final fallbackCountry = node.country?.trim().isNotEmpty == true
          ? node.country!.trim()
          : node.name.split('|').last.trim();
      final countryName =
          resolvedLocation?.country.trim().isNotEmpty == true &&
              resolvedLocation!.country != 'Unknown'
          ? resolvedLocation!.country
          : fallbackCountry;
      final countryCode =
          resolvedLocation?.countryCode.trim().isNotEmpty == true
          ? resolvedLocation!.countryCode
          : LocationResolver.canonicalCountryCode(countryName);
      final installed = await installedApplications();
      final installedPackages = installed
          .map((app) => app['packageName']?.toString())
          .whereType<String>()
          .toSet();
      await _channel.invokeMethod<void>('startVpn', {
        'config': _encodeConfiguration(node),
        'nodeId': node.id,
        'countryName': countryName,
        'countryCode': countryCode,
        'tunnelEngine': _debugTunnelEngine,
        'splitTunnelMode': splitTunnelPolicy.mode.name,
        'splitTunnelPackages':
            splitTunnelPolicy.packageNames
                .intersection(installedPackages)
                .toList()
              ..sort(),
      });
      // The native service sends the start result only after its own real
      // Google/YouTube dataplane verification succeeds. Consume that proof
      // in the first verify call instead of running the same probes twice.
      _startWasDataplaneVerified = true;
    } on PlatformException catch (error) {
      // The permission request is completed separately before start(). A
      // startVpn failure is therefore endpoint/startup specific and may be
      // retried with the next ranked node in the same country.
      throw CoreException(
        error.message ?? 'Android VPN startup failed.',
        retryable: true,
      );
    }
  }

  Future<CoreProbeMeasurement> probeNode(VpnNode node) async {
    try {
      final response = await _channel
          .invokeMapMethod<Object?, Object?>('probeNode', {
            'config': _encodeConfiguration(node),
            'traceNodeId': node.id,
            'traceCountry': node.country ?? 'unknown',
          });
      final reachable = response?['success'] == true;
      final latencyMs = response?['latencyMs'];
      return CoreProbeMeasurement(
        reachable: reachable,
        latency: reachable && latencyMs is num && latencyMs > 0
            ? Duration(milliseconds: latencyMs.toInt())
            : null,
      );
    } on PlatformException catch (error) {
      throw CoreException(
        error.message ?? 'VPN node probe failed.',
        retryable: true,
      );
    }
  }

  /// Measures up to ten destinations with one isolated native Xray runtime.
  /// Every destination has a dedicated inbound routed to its own outbound; the
  /// returned value is the warmed HTTP RTT, never core startup or cold connect.
  Future<Map<String, Duration?>> pingDestinations(
    List<VpnNode> nodes, {
    int worker = 0,
  }) async {
    if (nodes.isEmpty) return const {};
    if (nodes.length > 10) {
      throw ArgumentError('A native RTT worker accepts at most ten nodes.');
    }
    final response = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'pingDestinations',
      {
        'worker': worker,
        'nodes': nodes
            .map(
              (node) => {
                'nodeId': node.id,
                'country': node.country ?? node.name,
                'config': _encodeConfiguration(node),
              },
            )
            .toList(),
      },
    );
    return {
      for (final item in response ?? const <Map<Object?, Object?>>[])
        if (item['nodeId'] is String)
          item['nodeId'] as String:
              item['success'] == true &&
                  item['latencyMs'] is num &&
                  (item['latencyMs'] as num) > 0
              ? Duration(milliseconds: (item['latencyMs'] as num).toInt())
              : null,
    };
  }

  /// Stops the isolated destination-ping service after a hard timeout. This
  /// prevents a stalled native Xray request from blocking the next RTT probe.
  Future<void> cancelDestinationPings() async {
    await _channel.invokeMethod<void>('cancelDestinationPings');
    // The service runs in its own Android process. Let its onDestroy handler
    // retire the libXray runtime before the next queued probe starts.
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  /// Fetches over the underlying non-VPN Android network when available.
  /// This is used for the first subscription-refresh attempt while Connecso
  /// is already connected.
  Future<SubscriptionHttpResponse> fetchDirectSubscription(
    Uri endpoint,
    Map<String, String> requestHeaders,
  ) async {
    final response = await _fetchSubscriptionRoute(
      'fetchDirectSubscription',
      endpoint,
      requestHeaders,
    );
    return response;
  }

  String _encodeConfiguration(VpnNode node) {
    for (final warning in node.importWarnings) {
      developer.log('node=${node.id} $warning', name: 'CONNECSO/METADATA');
    }
    final config = XrayConfigBuilder(
      fakeDnsEnabled: fakeDnsEnabled,
    ).build(node);
    final outbounds = config['outbounds'] as List;
    final outbound = outbounds.first as Map;
    final stream = outbound['streamSettings'] as Map? ?? const {};
    developer.log(
      'event=xray.metadata_ready node=${node.id} protocol=${node.protocol.name} transport=${stream['network']} source=${node.sourceMetadata['format'] ?? 'legacy-cache'} preserved=true inbound=127.0.0.1:10808',
      name: 'CONNECSO/METADATA',
    );
    return jsonEncode(config);
  }

  Future<SubscriptionHttpResponse> fetchCurrentRouteSubscription(
    Uri endpoint,
    Map<String, String> requestHeaders,
  ) async {
    return _fetchSubscriptionRoute(
      'fetchCurrentRouteSubscription',
      endpoint,
      requestHeaders,
    );
  }

  Future<SubscriptionHttpResponse> _fetchSubscriptionRoute(
    String method,
    Uri endpoint,
    Map<String, String> requestHeaders,
  ) async {
    final response = await _channel.invokeMapMethod<Object?, Object?>(method, {
      'url': endpoint.toString(),
      'headers': requestHeaders,
    });
    // Android returns the response body as Base64 so arbitrary subscription
    // bytes survive the MethodChannel transport. Keep accepting the legacy
    // plain-text key for compatibility with older native builds.
    final encodedBody = response?['bodyBase64'];
    final body = response?['body'] is String
        ? response!['body'] as String
        : encodedBody is String
        ? utf8.decode(base64Decode(encodedBody), allowMalformed: false)
        : null;
    final headers = response?['headers'];
    if (body is! String || headers is! Map) {
      throw const CoreException('Direct subscription fetch returned no data.');
    }
    return SubscriptionHttpResponse(
      body: body,
      headers: headers.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
    );
  }

  @override
  Future<void> stop() async {
    _startWasDataplaneVerified = false;
    try {
      await _channel.invokeMethod<void>('stopVpn');
    } on PlatformException catch (error) {
      throw CoreException(error.message ?? 'Android VPN shutdown failed.');
    }
  }

  @override
  Future<bool> verifyUsableConnectivity() async {
    if (_startWasDataplaneVerified) {
      _startWasDataplaneVerified = false;
      return true;
    }
    return await _channel.invokeMethod<bool>('verifyConnectivity') ?? false;
  }

  @override
  Future<CoreStats> readStats() async {
    try {
      final stats =
          await _channel.invokeMapMethod<String, int>('readStats') ?? const {};
      final uploadBytes = stats['uploadBytes'];
      final downloadBytes = stats['downloadBytes'];
      if (uploadBytes == null || downloadBytes == null) {
        throw const CoreException('VPN traffic statistics are unavailable.');
      }
      return CoreStats(uploadBytes: uploadBytes, downloadBytes: downloadBytes);
    } on PlatformException catch (error) {
      throw CoreException(
        error.message ?? 'VPN traffic statistics are unavailable.',
      );
    }
  }
}
