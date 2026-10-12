import '../models/vpn_node.dart';
import 'split_tunnel_policy.dart';

class CoreException implements Exception {
  const CoreException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

class CoreStats {
  const CoreStats({required this.uploadBytes, required this.downloadBytes});
  final int uploadBytes;
  final int downloadBytes;
  int get totalBytes => uploadBytes + downloadBytes;
}

class CoreProbeMeasurement {
  const CoreProbeMeasurement({required this.reachable, this.latency});

  final bool reachable;
  final Duration? latency;
}

/// Optional measured-probe capability for cores that return endpoint timing.
abstract interface class MeasuredNodeProbe {
  Future<CoreProbeMeasurement> measureConnection(VpnNode node);
}

abstract interface class ProxyCore {
  ProxyCoreKind get kind;
  Future<void> initialize();
  Future<void> start(
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  });
  Future<void> stop();
  Future<void> restart(
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  });
  Future<void> reload(VpnNode node);
  Future<bool> testConnection(VpnNode node);
  Future<CoreStats> getStats();
  Set<String> get capabilities;
  String get version;
  Future<void> shutdown();
}

class CoreManager {
  CoreManager(this._core);
  final ProxyCore _core;
  bool _initializationFailed = false;
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _core.initialize();
    } catch (_) {
      _initializationFailed = true;
    }
  }

  ProxyCore? choose(VpnNode node) =>
      _initializationFailed || !_core.capabilities.contains(node.protocol.name)
      ? null
      : _core;

  Future<void> shutdown() => _core.shutdown();
}
