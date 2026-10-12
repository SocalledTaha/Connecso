import '../../domain/models/vpn_node.dart';
import '../../domain/services/core_manager.dart';
import '../../domain/services/split_tunnel_policy.dart';
import 'android_vpn_adapter.dart';

/// Android Xray adapter. The generated Go runtime is loaded only in the
/// dedicated VpnService process, never in Flutter's UI process.
class XrayProxyCore implements ProxyCore, MeasuredNodeProbe {
  const XrayProxyCore(this._vpn);

  final AndroidVpnAdapter _vpn;

  @override
  ProxyCoreKind get kind => ProxyCoreKind.xray;

  @override
  Set<String> get capabilities => const {
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'hysteria',
  };

  @override
  String get version => 'libXray-v26.9.9';

  @override
  Future<void> initialize() => _vpn.initializeCore();

  @override
  Future<void> start(
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  }) => _vpn.start(this, node, splitTunnelPolicy: splitTunnelPolicy);

  @override
  Future<void> stop() => _vpn.stop();

  @override
  Future<void> restart(
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  }) async {
    await stop();
    await start(node, splitTunnelPolicy: splitTunnelPolicy);
  }

  @override
  Future<void> reload(VpnNode node) => Future.error(
    const CoreException(
      'Xray configuration changes require a new VPN session.',
    ),
  );

  @override
  Future<bool> testConnection(VpnNode node) async =>
      (await _vpn.probeNode(node)).reachable;

  @override
  Future<CoreProbeMeasurement> measureConnection(VpnNode node) =>
      _vpn.probeNode(node);

  @override
  Future<CoreStats> getStats() => _vpn.readStats();

  @override
  Future<void> shutdown() => stop();
}
