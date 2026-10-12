import 'package:connecso_client/domain/models/vpn_node.dart';
import 'package:connecso_client/domain/services/probe_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bounds concurrency, skips disabled nodes and captures probe failures',
    () async {
      final probe = _FakeProbe();
      final results = await ProbeEngine(probe).probeBatch([
        _node('one'),
        _node('disabled', enabled: false),
        _node('throws'),
        _node('three'),
        _node('four'),
      ], concurrency: 2);

      expect(
        results.map((result) => result.nodeId),
        containsAll(['one', 'throws', 'three', 'four']),
      );
      expect(results, hasLength(4));
      expect(probe.peakConcurrency, 2);
      final failed = results.singleWhere((result) => result.nodeId == 'throws');
      expect(failed.reachable, isFalse);
      expect(failed.failureCategory, 'StateError');
    },
  );

  test('rejects an invalid concurrency limit', () {
    expect(
      () =>
          const ProbeEngine(_UnusedProbe())
              .probeBatch(const [], concurrency: 0),
      throwsArgumentError,
    );
  });
}

VpnNode _node(String id, {bool enabled = true}) => VpnNode(
  id: id,
  subscriptionId: 'test',
  name: id,
  protocol: ProxyProtocol.vless,
  host: '$id.example.com',
  port: 443,
  enabled: enabled,
);

class _FakeProbe implements NodeProbe {
  int active = 0;
  int peakConcurrency = 0;

  @override
  Future<ProbeResult> probe(VpnNode node) async {
    active++;
    if (active > peakConcurrency) peakConcurrency = active;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    active--;
    if (node.id == 'throws') throw StateError('sensitive underlying detail');
    return ProbeResult(
      nodeId: node.id,
      reachable: true,
      latency: const Duration(milliseconds: 30),
      failureCategory: null,
      checkedAt: DateTime.utc(2026, 9, 30),
    );
  }
}

class _UnusedProbe implements NodeProbe {
  const _UnusedProbe();

  @override
  Future<ProbeResult> probe(VpnNode node) => throw UnimplementedError();
}
