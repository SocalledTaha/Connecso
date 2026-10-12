import '../models/vpn_node.dart';
import 'core_manager.dart';
import 'probe_engine.dart';
import 'connect_trace.dart';

/// Measures node reachability through the configured core handshake.
class CoreNodeProbe implements NodeProbe {
  const CoreNodeProbe(this._cores);

  final CoreManager _cores;

  @override
  Future<ProbeResult> probe(VpnNode node) async {
    final checkedAt = DateTime.now();
    final stopwatch = Stopwatch()..start();
    try {
      await _cores.initialize();
      final core = _cores.choose(node);
      if (core == null) {
        return ProbeResult(
          nodeId: node.id,
          reachable: false,
          latency: null,
          failureCategory: 'core_unavailable',
          checkedAt: checkedAt,
        );
      }
      final measurement = core is MeasuredNodeProbe
          ? await (core as MeasuredNodeProbe).measureConnection(node)
          : CoreProbeMeasurement(
              reachable: await core.testConnection(node),
              latency: null,
            );
      stopwatch.stop();
      ConnectTrace.emit(
        'ping.pipeline_result node=${node.id} country=${node.country ?? 'unknown'} warmTtfb=${measurement.latency?.inMilliseconds ?? 'unknown'}ms uiPing=pending total=${stopwatch.elapsedMilliseconds}ms',
      );
      return ProbeResult(
        nodeId: node.id,
        reachable: measurement.reachable,
        latency: measurement.reachable
            ? measurement.latency
            : null,
        failureCategory: measurement.reachable ? null : 'probe_failed',
        checkedAt: checkedAt,
      );
    } catch (error) {
      stopwatch.stop();
      return ProbeResult(
        nodeId: node.id,
        reachable: false,
        latency: null,
        failureCategory: error.runtimeType.toString(),
        checkedAt: checkedAt,
      );
    }
  }
}
