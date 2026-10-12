import 'vpn_node.dart';

enum ConnectionMethod {
  ws('WS'),
  xhttp('XHTTP'),
  hysteria2('Hysteria2');

  const ConnectionMethod(this.label);
  final String label;

  bool matches(VpnNode node) {
    final transport = node.transport.toLowerCase();
    return switch (this) {
      ws => transport == 'ws' || transport == 'websocket',
      xhttp => transport == 'xhttp' || transport == 'splithttp',
      // One user-facing family; preserve each node's real version/settings.
      // Existing Xray nodes use protocol=hysteria, with version defaulting to 2.
      hysteria2 =>
        node.protocol == ProxyProtocol.hysteria ||
            transport == 'hysteria' ||
            transport == 'hysteria2',
    };
  }

  static List<ConnectionMethod> available(List<VpnNode> nodes) => values
      .where((method) => nodes.any((n) => n.enabled && method.matches(n)))
      .toList();
}
