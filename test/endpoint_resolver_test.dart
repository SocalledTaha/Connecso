import 'package:connecso_client/domain/models/destination_selection.dart';
import 'package:connecso_client/domain/models/connection_method.dart';
import 'package:connecso_client/domain/models/vpn_node.dart';
import 'package:connecso_client/domain/services/core_manager.dart';
import 'package:connecso_client/domain/services/endpoint_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'probes every candidate in the selected country tier and ranks them',
    () async {
      final core = _ProbeCore();
      final resolver = EndpointResolver(cores: CoreManager(core));
      final nodes = [
        _node('slow', 'NL', 300),
        _node('fast', 'NL', 80),
        _node('other-country', 'DE', 10),
      ];

      final result = await resolver.resolve(
        nodes: nodes,
        selection: const DestinationSelection.country('NL'),
      );

      expect(result.node.id, 'fast');
      expect(core.probed, containsAll(['fast', 'slow']));
      expect(core.probed, isNot(contains('other-country')));
    },
  );

  test('manual protocol selection only narrows the endpoint pool', () async {
    final core = _ProbeCore();
    final resolver = EndpointResolver(cores: CoreManager(core));
    final nodes = [
      _nodeWithTransport('ws', 'NL', 'ws', 100),
      _nodeWithTransport('xhttp', 'NL', 'xhttp', 20),
      _nodeWithTransport('hy2', 'NL', 'hysteria', 10),
    ];

    final result = await resolver.resolve(
      nodes: nodes,
      selection: const DestinationSelection.country(
        'NL',
        method: ConnectionMethod.xhttp,
      ),
    );

    expect(result.node.id, 'xhttp');
    expect(core.probed, ['xhttp']);
  });

  test('hysteria2 selection matches the hysteria transport family', () async {
    final core = _ProbeCore();
    final resolver = EndpointResolver(cores: CoreManager(core));
    final nodes = [
      _nodeWithTransport('ws', 'NL', 'ws', 10),
      _nodeWithTransport('hy2', 'NL', 'hysteria', 40),
    ];

    final result = await resolver.resolve(
      nodes: nodes,
      selection: const DestinationSelection.auto(
        method: ConnectionMethod.hysteria2,
      ),
    );

    expect(result.node.id, 'hy2');
    expect(core.probed, ['hy2']);
  });

  test(
    'unknown-country connection remains selectable by exact node id',
    () async {
      final core = _ProbeCore();
      final resolver = EndpointResolver(cores: CoreManager(core));
      final selected = _node('opaque-node', '', 55);
      final result = await resolver.resolve(
        nodes: [selected, _node('other-node', 'DE', 20)],
        selection: const DestinationSelection.country(
          'UNKNOWN',
          nodeId: 'opaque-node',
        ),
      );

      expect(result.node.id, 'opaque-node');
    },
  );

  test(
    'returns every reachable same-country candidate for tunnel fallback',
    () async {
      final core = _ProbeCore();
      final resolver = EndpointResolver(cores: CoreManager(core));
      final result = await resolver.resolveCandidates(
        nodes: [
          _node('first', 'DE', 90),
          _node('second', 'DE', 120),
          _node('other-country', 'FR', 20),
        ],
        selection: const DestinationSelection.country('DE'),
      );

      expect(result.endpoints.map((endpoint) => endpoint.node.id), [
        'first',
        'second',
      ]);
      expect(result.checkedNodeIds, containsAll(['first', 'second']));
      expect(core.probed, containsAll(['first', 'second']));
      expect(core.probed, isNot(contains('other-country')));
    },
  );

  test(
    'expands to the next priority tier only when the current tier has no reachable node',
    () async {
      final core = _ProbeCore()..unreachableIds.add('germany');
      final resolver = EndpointResolver(cores: CoreManager(core));
      final result = await resolver.resolveCandidates(
        nodes: [_node('germany', 'DE', 90), _node('france', 'FR', 120)],
        selection: const DestinationSelection.auto(),
      );

      expect(result.endpoints.single.node.id, 'france');
      expect(core.probed, ['germany', 'france']);
    },
  );
}

VpnNode _node(String id, String country, int latency) => VpnNode(
  id: id,
  subscriptionId: 'test',
  name: '$country $id',
  protocol: ProxyProtocol.vless,
  host: '$id.example.com',
  port: 443,
  countryCode: country,
  latency: Duration(milliseconds: latency),
  health: NodeHealth.healthy,
);

VpnNode _nodeWithTransport(
  String id,
  String country,
  String transport,
  int latency,
) => VpnNode(
  id: id,
  subscriptionId: 'test',
  name: '$country $id',
  protocol: transport == 'hysteria'
      ? ProxyProtocol.hysteria
      : ProxyProtocol.vless,
  transport: transport,
  host: '$id.example.com',
  port: 443,
  countryCode: country,
  latency: Duration(milliseconds: latency),
  health: NodeHealth.healthy,
);

class _ProbeCore implements ProxyCore {
  final probed = <String>[];
  final unreachableIds = <String>{};
  @override
  ProxyCoreKind get kind => ProxyCoreKind.xray;
  @override
  Set<String> get capabilities => const {'vless', 'hysteria'};
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
  Future<bool> testConnection(VpnNode node) async {
    probed.add(node.id);
    return !unreachableIds.contains(node.id);
  }

  @override
  Future<CoreStats> getStats() async =>
      const CoreStats(uploadBytes: 0, downloadBytes: 0);
  @override
  Future<void> shutdown() async {}
}
