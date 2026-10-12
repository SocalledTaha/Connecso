import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/models/vpn_node.dart';
import '../../domain/services/connection_manager.dart';
import '../../domain/services/core_manager.dart';
import '../../domain/services/split_tunnel_policy.dart';
import '../../domain/services/xray_config_builder.dart';
import '../../data/repositories/subscription_repository.dart';

class AndroidVpnAdapter implements TunnelAdapter {
  static const _channel = MethodChannel('com.connecso.client/vpn');
  static const _debugTunnelEngine = String.fromEnvironment(
    'CONNECSO_TUNNEL_ENGINE',
    defaultValue: 'AUTO',
  );
  final Map<String, Future<Uint8List?>> _applicationIconCache = {};
  bool _startWasDataplaneVerified = false;
  VoidCallback? _externalStateChanged;

  void setExternalStateChangedHandler(VoidCallback handler) {
    _externalStateChanged = handler;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'vpnStateChanged') {
        _externalStateChanged?.call();
      }
    });
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

  @override
  Future<void> start(
    ProxyCore core,
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  }) async {
    _startWasDataplaneVerified = false;
    try {
      final installed = await installedApplications();
      final installedPackages = installed
          .map((app) => app['packageName']?.toString())
          .whereType<String>()
          .toSet();
      await _channel.invokeMethod<void>('startVpn', {
        'config': _encodeConfiguration(node),
        'nodeId': node.id,
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
      throw CoreException(error.message ?? 'Android VPN startup failed.');
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

  /// Fetches over the underlying non-VPN Android network when available.
  /// This is used for the first subscription-refresh attempt while Connecso
  /// is already connected.
  Future<SubscriptionHttpResponse> fetchDirectSubscription(Uri endpoint) async {
    final response = await _fetchSubscriptionRoute(
      'fetchDirectSubscription',
      endpoint,
    );
    return response;
  }

  String _encodeConfiguration(VpnNode node) {
    for (final warning in node.importWarnings) {
      developer.log('node=${node.id} $warning', name: 'CONNECSO/METADATA');
    }
    final config = const XrayConfigBuilder().build(node);
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
  ) async {
    return _fetchSubscriptionRoute('fetchCurrentRouteSubscription', endpoint);
  }

  Future<SubscriptionHttpResponse> _fetchSubscriptionRoute(
    String method,
    Uri endpoint,
  ) async {
    final response = await _channel.invokeMapMethod<Object?, Object?>(method, {
      'url': endpoint.toString(),
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
