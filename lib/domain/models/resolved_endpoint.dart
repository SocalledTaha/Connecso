import 'vpn_node.dart';

enum SelectionReason { automatic, countryLocked, failover }

class ResolvedEndpoint {
  const ResolvedEndpoint({
    required this.node,
    required this.reason,
    this.requestedCountryCode,
  });

  final VpnNode node;
  final String? requestedCountryCode;
  final SelectionReason reason;
}
