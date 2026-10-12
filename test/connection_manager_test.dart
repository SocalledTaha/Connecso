import 'package:connecso_client/domain/models/connection_state.dart';
import 'package:connecso_client/domain/models/resolved_endpoint.dart';
import 'package:connecso_client/domain/models/vpn_node.dart';
import 'package:connecso_client/domain/services/connection_manager.dart';
import 'package:connecso_client/domain/services/core_manager.dart';
import 'package:connecso_client/domain/services/split_tunnel_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = SplitTunnelPolicy(mode: SplitTunnelMode.excludeSelected, packageNames: {});

  test('restores and clears an Android VPN session', () {
    final manager = ConnectionManager(tunnel: _FakeTunnel(), cores: CoreManager(_FakeCore()));
    manager.restoreConnectedSession();
    expect(manager.status.phase, ConnectionPhase.connected);
    manager.restoreDisconnectedSession();
    expect(manager.status.phase, ConnectionPhase.disconnected);
  });

  test('connects one already-resolved endpoint through the shared pipeline', () async {
    final tunnel = _FakeTunnel();
    final manager = ConnectionManager(tunnel: tunnel, cores: CoreManager(_FakeCore()));
    final selected = await manager.connect(
      ResolvedEndpoint(node: _node('primary'), reason: SelectionReason.automatic),
      splitTunnelPolicy: policy,
    );
    expect(selected.id, 'primary');
    expect(tunnel.startedNodeIds, ['primary']);
    expect(tunnel.permissionRequests, 1);
    expect(manager.status.phase, ConnectionPhase.connected);
  });

  test('fails closed when the selected protocol has no compatible core', () async {
    final tunnel = _FakeTunnel();
    final manager = ConnectionManager(tunnel: tunnel, cores: CoreManager(_FakeCore(supportedProtocols: const {})));
    await expectLater(
      manager.connect(
        ResolvedEndpoint(node: _node('unsupported'), reason: SelectionReason.automatic),
        splitTunnelPolicy: policy,
      ),
      throwsA(isA<CoreException>()),
    );
    expect(tunnel.permissionRequests, 0);
    expect(manager.status.phase, ConnectionPhase.failed);
  });

  test('reconnect stops the old tunnel before starting the replacement', () async {
    final tunnel = _FakeTunnel();
    final manager = ConnectionManager(tunnel: tunnel, cores: CoreManager(_FakeCore()));
    await manager.connect(
      ResolvedEndpoint(node: _node('first'), reason: SelectionReason.automatic),
      splitTunnelPolicy: policy,
    );
    final replacement = await manager.reconnect(
      ResolvedEndpoint(node: _node('second'), reason: SelectionReason.countryLocked, requestedCountryCode: 'DE'),
      splitTunnelPolicy: policy,
    );
    expect(replacement.id, 'second');
    expect(tunnel.startedNodeIds, ['first', 'second']);
    expect(tunnel.stopCalls, 1);
    expect(manager.status.phase, ConnectionPhase.connected);
  });
}

VpnNode _node(String id) => VpnNode(
  id: id,
  subscriptionId: 'test',
  name: id,
  protocol: ProxyProtocol.vless,
  host: '$id.example.com',
  port: 443,
  successCount: 10,
  stabilityScore: .8,
  health: NodeHealth.healthy,
  latency: const Duration(milliseconds: 120),
);

class _FakeTunnel implements TunnelAdapter {
  final startedNodeIds = <String>[];
  int permissionRequests = 0;
  int stopCalls = 0;
  @override Future<void> requestPermission() async => permissionRequests++;
  @override Future<void> start(ProxyCore core, VpnNode node, {required SplitTunnelPolicy splitTunnelPolicy}) async => startedNodeIds.add(node.id);
  @override Future<void> stop() async => stopCalls++;
  @override Future<bool> verifyUsableConnectivity() async => true;
  @override Future<CoreStats> readStats() async => const CoreStats(uploadBytes: 0, downloadBytes: 0);
}

class _FakeCore implements ProxyCore {
  _FakeCore({this.supportedProtocols = const {'vless'}});
  final Set<String> supportedProtocols;
  @override ProxyCoreKind get kind => ProxyCoreKind.xray;
  @override Set<String> get capabilities => supportedProtocols;
  @override String get version => 'test';
  @override Future<void> initialize() async {}
  @override Future<void> start(VpnNode node, {required SplitTunnelPolicy splitTunnelPolicy}) async {}
  @override Future<void> stop() async {}
  @override Future<void> restart(VpnNode node, {required SplitTunnelPolicy splitTunnelPolicy}) async {}
  @override Future<void> reload(VpnNode node) async {}
  @override Future<bool> testConnection(VpnNode node) async => true;
  @override Future<CoreStats> getStats() async => const CoreStats(uploadBytes: 0, downloadBytes: 0);
  @override Future<void> shutdown() async {}
}
