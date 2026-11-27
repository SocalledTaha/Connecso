import 'package:connecso_client/domain/models/connection_state.dart';
import 'package:connecso_client/domain/models/resolved_endpoint.dart';
import 'package:connecso_client/domain/models/vpn_node.dart';
import 'package:connecso_client/domain/services/connection_manager.dart';
import 'package:connecso_client/domain/services/core_manager.dart';
import 'package:connecso_client/domain/services/endpoint_resolver.dart';
import 'package:connecso_client/domain/services/split_tunnel_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'retries the next ranked candidate after endpoint startup failure',
    () async {
      final core = _FakeCore();
      final tunnel = _FakeTunnel(failStartNodeIds: {'first'});
      final manager = ConnectionManager(
        tunnel: tunnel,
        cores: CoreManager(core),
      );
      final nodes = [_node('first'), _node('second')];
      final resolution = EndpointResolution(
        endpoints: [
          for (final node in nodes)
            ResolvedEndpoint(
              node: node,
              requestedCountryCode: 'DE',
              reason: SelectionReason.countryLocked,
            ),
        ],
        checkedNodeIds: {'first', 'second'},
      );

      final connected = await manager.connectWithFailover(
        resolve: (_) async => resolution,
        splitTunnelPolicy: const SplitTunnelPolicy(
          mode: SplitTunnelMode.excludeSelected,
          packageNames: {},
        ),
      );

      expect(connected.id, 'second');
      expect(tunnel.startedNodeIds, ['first', 'second']);
      expect(manager.status.phase, ConnectionPhase.connected);
    },
  );

  test(
    'does not retry non-endpoint failures such as VPN permission denial',
    () async {
      final core = _FakeCore();
      final tunnel = _FakeTunnel(permissionDenied: true);
      final manager = ConnectionManager(
        tunnel: tunnel,
        cores: CoreManager(core),
      );
      final nodes = [_node('first'), _node('second')];
      var resolveCalls = 0;

      await expectLater(
        manager.connectWithFailover(
          resolve: (_) async {
            resolveCalls++;
            return EndpointResolution(
              endpoints: [
                for (final node in nodes)
                  ResolvedEndpoint(
                    node: node,
                    requestedCountryCode: 'DE',
                    reason: SelectionReason.countryLocked,
                  ),
              ],
              checkedNodeIds: {'first', 'second'},
            );
          },
          splitTunnelPolicy: const SplitTunnelPolicy(
            mode: SplitTunnelMode.excludeSelected,
            packageNames: {},
          ),
        ),
        throwsA(isA<CoreException>()),
      );

      expect(resolveCalls, 1);
      expect(tunnel.startedNodeIds, isEmpty);
    },
  );
}

VpnNode _node(String id) => VpnNode(
  id: id,
  subscriptionId: 'test',
  name: 'Germany $id',
  protocol: ProxyProtocol.vless,
  host: '$id.example.com',
  port: 443,
  countryCode: 'DE',
);

class _FakeCore implements ProxyCore {
  @override
  Set<String> get capabilities => const {'vless'};
  @override
  ProxyCoreKind get kind => ProxyCoreKind.xray;
  @override
  String get version => 'test';
  @override
  Future<void> initialize() async {}
  @override
  Future<void> start(VpnNode node, {required splitTunnelPolicy}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> restart(VpnNode node, {required splitTunnelPolicy}) async {}
  @override
  Future<void> reload(VpnNode node) async {}
  @override
  Future<bool> testConnection(VpnNode node) async => true;
  @override
  Future<CoreStats> getStats() async =>
      const CoreStats(uploadBytes: 0, downloadBytes: 0);
  @override
  Future<void> shutdown() async {}
}

class _FakeTunnel implements TunnelAdapter {
  _FakeTunnel({
    this.failStartNodeIds = const {},
    this.permissionDenied = false,
  });

  final Set<String> failStartNodeIds;
  final bool permissionDenied;
  final startedNodeIds = <String>[];

  @override
  Future<void> requestPermission() async {
    if (permissionDenied) {
      throw const CoreException('VPN permission was not granted.');
    }
  }

  @override
  Future<void> start(
    ProxyCore core,
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  }) async {
    startedNodeIds.add(node.id);
    if (failStartNodeIds.contains(node.id)) {
      throw const CoreException('Node startup failed.', retryable: true);
    }
  }

  @override
  Future<void> stop() async {}
  @override
  Future<bool> verifyUsableConnectivity() async => true;
  @override
  Future<CoreStats> readStats() async =>
      const CoreStats(uploadBytes: 0, downloadBytes: 0);
}
