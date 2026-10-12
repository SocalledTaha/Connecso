import '../models/vpn_node.dart';

class ProbeResult {
  const ProbeResult({
    required this.nodeId,
    required this.reachable,
    required this.latency,
    required this.failureCategory,
    required this.checkedAt,
  });
  final String nodeId;
  final bool reachable;
  final Duration? latency;
  final String? failureCategory;
  final DateTime checkedAt;
}

abstract interface class NodeProbe {
  /// Implementations should test a real protocol/core handshake or usable
  /// routed request. TCP reachability is only an optional supporting signal.
  Future<ProbeResult> probe(VpnNode node);
}

class ProbeEngine {
  const ProbeEngine(this._probe);
  final NodeProbe _probe;

  Future<List<ProbeResult>> probeBatch(
    Iterable<VpnNode> nodes, {
    int concurrency = 3,
    Duration? timeout,
  }) async {
    if (concurrency < 1) {
      throw ArgumentError.value(
        concurrency,
        'concurrency',
        'Must be positive.',
      );
    }
    final queue = nodes.where((node) => node.enabled).toList();
    if (queue.isEmpty) return const [];
    final results = <ProbeResult>[];
    var index = 0;
    Future<void> worker() async {
      while (index < queue.length) {
        final current = index++;
        try {
          final probe = _probe.probe(queue[current]);
          results.add(
            timeout == null ? await probe : await probe.timeout(timeout),
          );
        } catch (error) {
          results.add(
            ProbeResult(
              nodeId: queue[current].id,
              reachable: false,
              latency: null,
              failureCategory: error.runtimeType.toString(),
              checkedAt: DateTime.now(),
            ),
          );
        }
      }
    }

    await Future.wait(
      List.generate(concurrency.clamp(1, 8).toInt(), (_) => worker()),
    );
    return results;
  }
}
