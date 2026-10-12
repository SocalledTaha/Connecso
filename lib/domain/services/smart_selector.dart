import '../models/vpn_node.dart';

class SmartSelector {
  const SmartSelector({this.switchMargin = 0.12});

  /// The challenger must outperform the current node by this fraction to avoid
  /// unnecessary movement between similarly healthy exits.
  final double switchMargin;

  RuntimeHealthState classifyRuntime(
    VpnNode current,
    Iterable<VpnNode> peers, {
    double consensus = .65,
  }) {
    if (current.runtimeState == RuntimeHealthState.hardFailure ||
        current.runtimeState == RuntimeHealthState.dead) {
      return current.runtimeState;
    }
    final currentDegraded = _isDegraded(current);
    if (!currentDegraded) return RuntimeHealthState.healthy;
    final relevant = peers
        .where(
          (node) =>
              node.id != current.id &&
              node.baselinePing != null &&
              node.authoritativeLatency != null &&
              node.authoritativeLatency!.inMilliseconds > 0,
        )
        .toList();
    if (relevant.isEmpty) return RuntimeHealthState.nodeSpecificDegraded;
    final degradedPeers = relevant.where(_isDegraded).length;
    if (degradedPeers / relevant.length >= consensus) {
      return RuntimeHealthState.globalNetworkDegraded;
    }
    return RuntimeHealthState.nodeSpecificDegraded;
  }

  bool _isDegraded(VpnNode node) {
    final baseline = node.baselinePing?.inMilliseconds;
    final latency = node.authoritativeLatency?.inMilliseconds;
    return baseline != null &&
        baseline > 0 &&
        latency != null &&
        latency >= baseline * 1.35;
  }

  VpnNode? select(Iterable<VpnNode> nodes, {VpnNode? current}) {
    final candidates = nodes
        .where((node) => node.enabled && node.health != NodeHealth.unhealthy)
        .toList();
    if (candidates.isEmpty) return null;
    final bestLatency = candidates
        .map((node) => node.authoritativeLatency?.inMilliseconds)
        .where((value) => value != null && value > 0)
        .whereType<int>()
        .fold<int?>(
          null,
          (best, value) => best == null || value < best ? value : best,
        );
    candidates.sort(
      (a, b) => _selectionScore(
        b,
        bestLatency,
      ).compareTo(_selectionScore(a, bestLatency)),
    );
    final best = candidates.first;
    if (current == null) return best;
    final currentIndex = candidates.indexWhere((node) => node.id == current.id);
    final currentCandidate = currentIndex < 0 ? null : candidates[currentIndex];
    if (currentCandidate == null) return best;
    final currentScore = _selectionScore(currentCandidate, bestLatency);
    final bestScore = _selectionScore(best, bestLatency);
    if (currentCandidate.id == best.id) return currentCandidate;
    if (currentScore > 0 && bestScore < currentScore * (1 + switchMargin)) {
      return currentCandidate;
    }
    return best;
  }

  double _selectionScore(VpnNode node, int? bestLatency) {
    final country = switch ((node.countryCode ?? node.country ?? '')
        .toLowerCase()) {
      'nl' || 'netherlands' => 60.0,
      'de' || 'germany' || 'gb' || 'uk' || 'united kingdom' => 50.0,
      'tr' || 'turkey' || 'fr' || 'france' || 'us' || 'united states' => 40.0,
      'ca' || 'canada' || 'it' || 'italy' => 30.0,
      _ => 0.0,
    };
    final ping = node.authoritativeLatency == null || bestLatency == null
        ? 0.0
        : (40 * bestLatency / node.authoritativeLatency!.inMilliseconds).clamp(
            0,
            40,
          );
    // Keep the history bonus on the concrete node, never on its country. A
    // country can contain several transports with very different metadata;
    // only the exact node that recently carried a verified session deserves
    // the reconnect preference.
    final lastGood =
        node.lastSuccess != null &&
            DateTime.now().difference(node.lastSuccess!).inHours < 24
        ? 60.0
        : 0.0;
    // Initial selection is intentionally limited to the agreed three terms.
    return country + ping + lastGood;
  }

  double degradationPenalty(VpnNode node) {
    final baseline =
        node.baselinePing?.inMilliseconds ??
        (node.last5Pings.isEmpty
            ? 0
            : node.last5Pings.reduce((a, b) => a + b) ~/
                  node.last5Pings.length);
    final current = node.authoritativeLatency?.inMilliseconds ?? baseline;
    if (baseline <= 0 || current <= baseline * 1.35) return 0;
    final ratio = current / baseline;
    if (ratio >= 2.7) return 35;
    if (ratio >= 2.2) return 25;
    if (ratio >= 1.8) return 15;
    if (ratio >= 1.45) return 10;
    return 5;
  }

  double runtimeScore(VpnNode node, int? bestLatency) {
    final initial = _selectionScore(node, bestLatency);
    if (node.runtimeState == RuntimeHealthState.globalNetworkDegraded) {
      return initial;
    }
    final penalty = node.runtimeState == RuntimeHealthState.nodeSpecificDegraded
        ? degradationPenalty(node)
        : 0;
    return initial - penalty;
  }

  int tier(VpnNode node) {
    final country = _resolvedCountry(node);
    if ({
      'nl',
      'netherlands',
      'de',
      'germany',
      'gb',
      'uk',
      'united kingdom',
      'tr',
      'turkey',
    }.contains(country))
      return 1;
    if ({'fr', 'france', 'us', 'united states'}.contains(country)) return 2;
    if ({'ca', 'canada', 'it', 'italy'}.contains(country)) return 3;
    return 4;
  }

  String _resolvedCountry(VpnNode node) {
    final explicit = (node.countryCode ?? node.country ?? '')
        .trim()
        .toLowerCase();
    if (explicit.isNotEmpty && explicit != 'unknown') return explicit;
    final text = '${node.name} ${node.city ?? ''}'.toLowerCase();
    const aliases = {
      'netherlands': 'netherlands',
      'amsterdam': 'netherlands',
      'nl-': 'nl',
      'germany': 'germany',
      'frankfurt': 'germany',
      'de-': 'de',
      'united kingdom': 'uk',
      'london': 'uk',
      'uk-': 'uk',
      'turkey': 'turkey',
      'istanbul': 'turkey',
      'tr-': 'tr',
      'france': 'france',
      'paris': 'france',
      'fr-': 'fr',
      'united states': 'united states',
      'new york': 'united states',
      'us-': 'us',
      'canada': 'canada',
      'toronto': 'canada',
      'ca-': 'ca',
      'italy': 'italy',
      'milan': 'italy',
      'it-': 'it',
    };
    for (final entry in aliases.entries) {
      if (text.contains(entry.key)) return entry.value;
    }
    return explicit;
  }

  double score(VpnNode node) {
    if (!node.enabled || node.health == NodeHealth.unhealthy) return -1;
    final latencyScore = node.authoritativeLatency == null
        ? 0.35
        : (1 - (node.authoritativeLatency!.inMilliseconds / 2000))
              .clamp(0, 1)
              .toDouble();
    final successTotal = node.successCount + node.failureCount;
    final reliability = successTotal == 0
        ? 0.5
        : node.successCount / successTotal;
    final ageHours = node.lastSuccess == null
        ? null
        : DateTime.now().difference(node.lastSuccess!).inHours.clamp(0, 72);
    final recency = ageHours == null
        ? 0.35
        : (1 - ageHours / 96).clamp(0, 1).toDouble();
    final health = switch (node.health) {
      NodeHealth.healthy => 1.0,
      NodeHealth.degraded => 0.45,
      NodeHealth.unknown => 0.35,
      NodeHealth.unhealthy => 0.0,
    };
    final connectScore = node.connectionEstablishmentTime == null
        ? 0.5
        : (1 - (node.connectionEstablishmentTime!.inMilliseconds / 15000))
              .clamp(0, 1)
              .toDouble();
    return 0.28 * reliability +
        0.24 * node.stabilityScore.clamp(0, 1) +
        0.20 * latencyScore +
        0.12 * recency +
        0.10 * health +
        0.06 * connectScore;
  }
}
