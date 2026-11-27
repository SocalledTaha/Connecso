import 'dart:async';
import 'dart:developer' as developer;

import '../models/destination_selection.dart';
import '../models/resolved_endpoint.dart';
import '../models/vpn_node.dart';
import 'core_manager.dart';
import 'location_resolver.dart';
import 'smart_selector.dart';

/// A ranked set of reachable candidates from the highest viable tier.
/// [checkedNodeIds] also includes nodes that were probed and found unreachable,
/// so a later failover pass can expand to the next tier without probing them
/// again.
class EndpointResolution {
  const EndpointResolution({
    required this.endpoints,
    required this.checkedNodeIds,
  });

  final List<ResolvedEndpoint> endpoints;
  final Set<String> checkedNodeIds;
}

class EndpointResolver {
  EndpointResolver({
    required CoreManager cores,
    SmartSelector selector = const SmartSelector(),
  }) : _cores = cores,
       _selector = selector;

  // Native pingBatch uses the same Xray runtime, so keep candidate probes
  // serialized and bounded. This is a reachability check, not the displayed
  // warm HTTP ping used by the connected-session UI.
  static const probeTimeout = Duration(seconds: 3);
  final CoreManager _cores;
  final SmartSelector _selector;

  Future<ResolvedEndpoint> resolve({
    required Iterable<VpnNode> nodes,
    required DestinationSelection selection,
    VpnNode? current,
    Set<String> excludedNodeIds = const {},
    SelectionReason? reason,
    String? lastGoodNodeId,
    Set<String> preferredCountryCodes = const {},
  }) async {
    final result = await resolveCandidates(
      nodes: nodes,
      selection: selection,
      current: current,
      excludedNodeIds: excludedNodeIds,
      reason: reason,
      lastGoodNodeId: lastGoodNodeId,
      preferredCountryCodes: preferredCountryCodes,
    );
    if (result.endpoints.isEmpty) {
      throw const CoreException('No reachable endpoint matched the selection.');
    }
    return result.endpoints.first;
  }

  Future<EndpointResolution> resolveCandidates({
    required Iterable<VpnNode> nodes,
    required DestinationSelection selection,
    VpnNode? current,
    Set<String> excludedNodeIds = const {},
    SelectionReason? reason,
    String? lastGoodNodeId,
    Set<String> preferredCountryCodes = const {},
  }) async {
    await _cores.initialize();
    final canonicalSelection = selection.countryCode == null
        ? ''
        : LocationResolver.canonicalCountryCode(selection.countryCode!);
    // A node can have no recognizable country metadata. Its synthetic UI
    // group is still selectable by exact nodeId; do not filter it out because
    // the synthetic label itself is not an ISO country code.
    final requestedCountry = canonicalSelection.isEmpty
        ? null
        : canonicalSelection;
    final allEligible = nodes.where((node) {
      if (excludedNodeIds.contains(node.id) ||
          !node.enabled ||
          node.health == NodeHealth.unhealthy ||
          node.runtimeState == RuntimeHealthState.dead ||
          _cores.choose(node) == null ||
          (selection.method != null && !selection.method!.matches(node))) {
        return false;
      }
      if (requestedCountry == null) return true;
      final nodeCountry = LocationResolver.canonicalCountryCode(
        '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
      );
      final resolvedCountry = nodeCountry.isNotEmpty
          ? nodeCountry
          : LocationResolver().resolve(node)?.countryCode ?? '';
      return resolvedCountry == requestedCountry;
    }).toList();

    final now = DateTime.now().toUtc();
    final eligible = allEligible.where((node) {
      final failure = node.lastFailure;
      final coolingDown =
          node.consecutiveFailures >= 2 &&
          failure != null &&
          now.difference(failure.toUtc()) < const Duration(minutes: 5);
      return !coolingDown;
    }).toList();
    // If every scoped candidate is cooling down, still give the scoped pool
    // one bounded attempt instead of making the selected country unavailable.
    final candidates = eligible.isEmpty ? allEligible : eligible;
    developer.log(
      'endpoint_scope country=${requestedCountry ?? 'AUTO'} method=${selection.method?.name ?? 'AUTO'} eligible=${candidates.length}',
      name: 'CONNECSO/Resolver',
    );
    if (candidates.isEmpty) {
      throw const CoreException('No usable subscription nodes.');
    }

    final checked = <String>{};
    final tiers = List<int>.generate(
      preferredCountryCodes.isEmpty ? 4 : 5,
      (index) => index + 1,
      growable: false,
    );
    final selectedNode = candidates
        .where((node) => node.id == selection.nodeId)
        .firstOrNull;
    final tierOrder = selectedNode == null
        ? tiers
        : [
            _selector.tier(
              selectedNode,
              preferredCountryCodes: preferredCountryCodes,
            ),
            ...tiers.where(
              (tier) =>
                  tier !=
                  _selector.tier(
                    selectedNode,
                    preferredCountryCodes: preferredCountryCodes,
                  ),
            ),
          ];
    for (final tier in tierOrder) {
      final tierNodes = candidates
          .where(
            (node) =>
                _selector.tier(
                  node,
                  preferredCountryCodes: preferredCountryCodes,
                ) ==
                tier,
          )
          .toList();
      if (tierNodes.isEmpty) continue;

      // Last Good and existing health scores only affect probe order. Every
      // candidate in this tier is still considered before choosing, so a
      // failed actual tunnel can fall through to another same-country node.
      tierNodes.sort((a, b) {
        final aExplicit = a.id == selection.nodeId;
        final bExplicit = b.id == selection.nodeId;
        if (aExplicit != bExplicit) return aExplicit ? -1 : 1;
        final aLastGood = a.id == lastGoodNodeId || a.id == current?.id;
        final bLastGood = b.id == lastGoodNodeId || b.id == current?.id;
        if (aLastGood != bLastGood) return aLastGood ? -1 : 1;
        if (current != null) {
          final affinity = _metadataAffinity(
            b,
            current,
          ).compareTo(_metadataAffinity(a, current));
          if (affinity != 0) return affinity;
        }
        final score = _selector.score(b).compareTo(_selector.score(a));
        if (score != 0) return score;
        return a.id.compareTo(b.id);
      });

      final reachable = <VpnNode>[];
      for (final node in tierNodes) {
        checked.add(node.id);
        if (_hasFreshSuccessfulProbe(node, now)) {
          reachable.add(node);
          developer.log(
            'endpoint_probe_cached node=${node.id} tier=$tier',
            name: 'CONNECSO/Resolver',
          );
          continue;
        }
        final core = _cores.choose(node);
        if (core == null) continue;
        final passed = await core
            .testConnection(node)
            .timeout(probeTimeout, onTimeout: () => false)
            .catchError((_) => false);
        developer.log(
          'endpoint_probe node=${node.id} tier=$tier success=$passed',
          name: 'CONNECSO/Resolver',
        );
        if (passed) {
          reachable.add(node);
          // Check every candidate in the current priority tier before ranking.
          // ConnectionManager needs the full reachable set to retry a sibling
          // immediately if the selected endpoint fails during tunnel startup.
        }
      }

      if (reachable.isEmpty) continue;
      final ranked = _rankCandidates(
        reachable,
        lastGoodNodeId: lastGoodNodeId ?? current?.id,
        preferredCountryCodes: preferredCountryCodes,
      );
      if (selection.nodeId != null &&
          ranked.any((node) => node.id == selection.nodeId)) {
        ranked.sort((a, b) {
          if (a.id == selection.nodeId) return -1;
          if (b.id == selection.nodeId) return 1;
          return 0;
        });
      }
      final selectionReason =
          reason ??
          (requestedCountry == null
              ? SelectionReason.automatic
              : SelectionReason.countryLocked);
      return EndpointResolution(
        checkedNodeIds: Set.unmodifiable(checked),
        endpoints: List.unmodifiable(
          ranked.map(
            (node) => ResolvedEndpoint(
              node: node,
              requestedCountryCode: requestedCountry,
              reason: selectionReason,
            ),
          ),
        ),
      );
    }
    return EndpointResolution(
      endpoints: const [],
      checkedNodeIds: Set.unmodifiable(checked),
    );
  }

  bool _hasFreshSuccessfulProbe(VpnNode node, DateTime now) {
    final probe = node.lastProbe;
    final success = node.lastSuccess;
    return node.runtimeState != RuntimeHealthState.hardFailure &&
        node.runtimeState != RuntimeHealthState.dead &&
        (node.runtimeState == RuntimeHealthState.healthy ||
            node.health == NodeHealth.healthy) &&
        node.authoritativeLatency != null &&
        probe != null &&
        now.difference(probe.toUtc()) <= const Duration(minutes: 5) &&
        (success == null ||
            now.difference(success.toUtc()) <= const Duration(minutes: 5));
  }

  List<VpnNode> _rankCandidates(
    List<VpnNode> nodes, {
    required String? lastGoodNodeId,
    required Set<String> preferredCountryCodes,
  }) {
    if (nodes.length < 2) return nodes;
    final measured = nodes
        .map((node) => node.authoritativeLatency?.inMilliseconds)
        .whereType<int>()
        .where((latency) => latency > 0)
        .toList();
    final bestLatency = measured.isEmpty
        ? null
        : measured.reduce((a, b) => a < b ? a : b);
    double score(VpnNode node) {
      final country = _countryPriority(node, preferredCountryCodes);
      final pingMs = node.authoritativeLatency?.inMilliseconds;
      final ping = bestLatency == null || pingMs == null || pingMs <= 0
          ? 0.0
          : (40 * bestLatency / pingMs).clamp(0.0, 40.0);
      final lastGood = node.id == lastGoodNodeId ? 20.0 : 0.0;
      return country + ping + lastGood;
    }

    return [...nodes]..sort((a, b) {
      final difference = score(b).compareTo(score(a));
      if (difference != 0) return difference;
      return a.id.compareTo(b.id);
    });
  }

  int _countryPriority(VpnNode node, Set<String> preferredCountryCodes) {
    final country = LocationResolver.canonicalCountryCode(
      '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
    ).toLowerCase();
    if (preferredCountryCodes.isNotEmpty) {
      return preferredCountryCodes
              .map((code) => code.toLowerCase())
              .contains(country)
          ? 60
          : 0;
    }
    if ({'nl', 'de', 'gb', 'uk'}.contains(country)) return 50;
    if ({'tr', 'fr', 'us'}.contains(country)) return 40;
    if ({'ca', 'it'}.contains(country)) return 30;
    return 0;
  }

  int _metadataAffinity(VpnNode candidate, VpnNode reference) {
    var score = 0;
    if (candidate.transport.toLowerCase() ==
        reference.transport.toLowerCase()) {
      score += 3;
    }
    if (candidate.protocol == reference.protocol) score += 2;
    if ((candidate.sni ?? '').toLowerCase() ==
        (reference.sni ?? '').toLowerCase()) {
      score++;
    }
    if ((candidate.fingerprint ?? 'chrome').toLowerCase() ==
        (reference.fingerprint ?? 'chrome').toLowerCase()) {
      score++;
    }
    for (final key in const [
      'security',
      'alpn',
      'echConfigList',
      'echForceQuery',
    ]) {
      if (candidate.credentials[key] != null &&
          candidate.credentials[key]!.toLowerCase() ==
              (reference.credentials[key] ?? '').toLowerCase()) {
        score++;
      }
    }
    return score;
  }
}
