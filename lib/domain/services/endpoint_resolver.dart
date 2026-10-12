import 'dart:async';
import 'dart:developer' as developer;

import '../models/destination_selection.dart';
import '../models/resolved_endpoint.dart';
import '../models/vpn_node.dart';
import 'core_manager.dart';
import 'location_resolver.dart';
import 'smart_selector.dart';

class EndpointResolver {
  EndpointResolver({
    required CoreManager cores,
    SmartSelector selector = const SmartSelector(),
  }) : _cores = cores,
       _selector = selector;

  // A dead endpoint must not stall the user-facing connection flow.  The
  // native probe already has its own bounded phases; three seconds is enough
  // to accept a responsive endpoint while allowing us to move to the next
  // candidate quickly.
  static const probeTimeout = Duration(seconds: 3);
  final CoreManager _cores;
  final SmartSelector _selector;

  Future<ResolvedEndpoint> resolve({
    required Iterable<VpnNode> nodes,
    required DestinationSelection selection,
    VpnNode? current,
    Set<String> excludedNodeIds = const {},
    SelectionReason? reason,
  }) async {
    await _cores.initialize();
    final requestedCountry = selection.countryCode == null
        ? null
        : LocationResolver.canonicalCountryCode(selection.countryCode!);
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
      // Use the same metadata resolver as the UI/map.  Subscription rows are
      // not consistent: some carry an ISO code, some a display name (often
      // prefixed, such as `XNetherlands`), and some only carry structured
      // location metadata.  Country locking must group all of those forms
      // without changing the node or the downstream dataplane.
      final nodeCountry = LocationResolver.canonicalCountryCode(
        '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
      );
      final resolvedCountry = nodeCountry.isNotEmpty
          ? nodeCountry
          : LocationResolver().resolve(node)?.countryCode ?? '';
      return resolvedCountry == requestedCountry;
    }).toList();
    final eligible = allEligible.where((node) {
      final failure = node.lastFailure;
      final coolingDown =
          node.consecutiveFailures >= 2 &&
          failure != null &&
          DateTime.now().toUtc().difference(failure.toUtc()) <
              const Duration(minutes: 5);
      return !coolingDown;
    }).toList();
    // Never make a destination unavailable only because every candidate has
    // a recent failure record. In that case, retry the complete scoped pool.
    final scopedEligible = eligible.isEmpty ? allEligible : eligible;
    developer.log(
      'endpoint_scope country=${requestedCountry ?? 'AUTO'} method=${selection.method?.name ?? 'AUTO'} eligible=${scopedEligible.length}',
      name: 'CONNECSO/Resolver',
    );
    if (scopedEligible.isEmpty) {
      throw const CoreException('No usable subscription nodes.');
    }
    final candidates = scopedEligible;

    // Connection startup must not wait on a serial subscription-wide probe
    // batch. SmartSelector already has the persisted health/latency history;
    // use that ordering immediately and let the real Android dataplane
    // verification validate the selected endpoint after Xray/TUN start.
    // A previously connected node is the fastest safe retry.  It has already
    // passed the full dataplane verification, and it is still constrained by
    // the country/method-filtered `eligible` pool above.  Re-probing it before
    // reconnecting only adds startup latency; the next background probe can
    // refresh its warm RTT after the tunnel is back.
    VpnNode? previous;
    if (current != null) {
      for (final node in candidates) {
        if (node.id == current.id) {
          previous = node;
          break;
        }
      }
    }
    final immediate =
        previous ?? _selector.select(candidates, current: current);
    // ConnectionManager only supplies `current` after the previous endpoint
    // has completed the real Android dataplane verification. Reuse that exact
    // endpoint on a same-scope reconnect even when the asynchronous warm-ping
    // persistence has not finished yet. The country/method-filtered candidate
    // list above remains the guard against carrying it into another scope.
    if (previous != null && current != null) {
      _assertInScope(previous, requestedCountry, selection);
      developer.log(
        'endpoint_verified_reuse node=${previous.id}',
        name: 'CONNECSO/Resolver',
      );
      return ResolvedEndpoint(
        node: previous,
        requestedCountryCode: requestedCountry,
        reason:
            reason ??
            (requestedCountry == null
                ? SelectionReason.automatic
                : SelectionReason.countryLocked),
      );
    }
    // Do not treat an unverified first node as an AutoSelector result.  Some
    // subscriptions put a deliberately incomplete transport variant first
    // (for example WS without ECH while the following variants have ECH). In
    // a country-locked scope that made the tunnel start successfully but left
    // the selected country's warm RTT unavailable. Only reuse an endpoint
    // when its persisted health and latency prove that this exact node has
    // already carried traffic.
    final immediateIsVerified =
        immediate != null &&
        immediate.authoritativeLatency != null &&
        (immediate.runtimeState == RuntimeHealthState.healthy ||
            immediate.health == NodeHealth.healthy);
    if (immediateIsVerified) {
      _assertInScope(immediate, requestedCountry, selection);
      developer.log(
        'endpoint_immediate node=${immediate.id}',
        name: 'CONNECSO/Resolver',
      );
      return ResolvedEndpoint(
        node: immediate,
        requestedCountryCode: requestedCountry,
        reason:
            reason ??
            (requestedCountry == null
                ? SelectionReason.automatic
                : SelectionReason.countryLocked),
      );
    }

    // A recently verified node is already an AutoSelector result. Re-probing
    // it synchronously on every tap only delays startVpn and can contend with
    // a background native probe. Use the cached proof for a short window;
    // failed sessions still fall through to the full probe path on retry.
    final now = DateTime.now().toUtc();
    final cached = candidates.where((node) {
      final success = node.lastSuccess;
      final probe = node.lastProbe;
      return (node.runtimeState == RuntimeHealthState.healthy ||
              node.health == NodeHealth.healthy) &&
          node.authoritativeLatency != null &&
          probe != null &&
          now.difference(probe.toUtc()) <= const Duration(minutes: 5) &&
          // Older cache records may have a valid probe/latency but no
          // lastSuccess field. The recent healthy probe is still sufficient
          // to avoid repeating a slow native handshake on the next tap.
          (success == null ||
              now.difference(success.toUtc()) <= const Duration(minutes: 5));
    }).toList();
    developer.log(
      'endpoint_cache_scan cached=${cached.length} candidates=${candidates.length} '
      'details=${candidates.map((node) => '${node.id}:${node.health.name}/${node.runtimeState.name}/'
          'lat=${node.authoritativeLatency?.inMilliseconds ?? -1}/'
          'probe=${node.lastProbe != null}/success=${node.lastSuccess != null}').join(',')}',
      name: 'CONNECSO/Resolver',
    );
    if (cached.isNotEmpty) {
      final selected = _selector.select(cached, current: current);
      if (selected != null) {
        developer.log(
          'endpoint_cached node=${selected.id} age=${now.difference((selected.lastSuccess ?? selected.lastProbe)!.toUtc()).inSeconds}s',
          name: 'CONNECSO/Resolver',
        );
        return ResolvedEndpoint(
          node: selected,
          requestedCountryCode: requestedCountry,
          reason:
              reason ??
              (requestedCountry == null
                  ? SelectionReason.automatic
                  : SelectionReason.countryLocked),
        );
      }
    }

    for (var tier = 1; tier <= 4; tier++) {
      final tierNodes = candidates
          .where((node) => _selector.tier(node) == tier)
          .toList();
      if (tierNodes.isEmpty) continue;
      // Once a session has carried traffic, keep its transport profile as a
      // cross-country preference (WS/XHTTP/Hysteria2, TLS/Reality, ALPN,
      // fingerprint and ECH). Country filtering still remains authoritative;
      // this only changes probe order inside the selected country.
      if (current != null) {
        tierNodes.sort(
          (a, b) => _metadataAffinity(
            b,
            current,
          ).compareTo(_metadataAffinity(a, current)),
        );
      }
      // Keep the established native probe serialization: one native Xray
      // probe at a time. This avoids racing independent temporary cores.
      final reachable = <VpnNode>[];
      for (final node in tierNodes) {
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
          // The dataplane will perform the authoritative verification after
          // Xray/TUN startup. Once one candidate in the requested scope has
          // passed the native probe, probing every sibling serially only adds
          // seconds to connection startup and does not improve readiness.
          break;
        }
      }
      if (reachable.isEmpty) continue;
      final selected = _selector.select(reachable, current: current);
      if (selected == null) continue;
      return ResolvedEndpoint(
        node: selected,
        requestedCountryCode: requestedCountry,
        reason:
            reason ??
            (requestedCountry == null
                ? SelectionReason.automatic
                : SelectionReason.countryLocked),
      );
    }
    throw const CoreException('No reachable endpoint matched the selection.');
  }

  int _metadataAffinity(VpnNode candidate, VpnNode reference) {
    var score = 0;
    if (candidate.transport.toLowerCase() ==
        reference.transport.toLowerCase()) {
      score += 3;
    }
    if (candidate.protocol == reference.protocol) score += 2;
    if ((candidate.sni ?? '').toLowerCase() ==
        (reference.sni ?? '').toLowerCase())
      score++;
    if ((candidate.fingerprint ?? 'chrome').toLowerCase() ==
        (reference.fingerprint ?? 'chrome').toLowerCase())
      score++;
    for (final key in const [
      'security',
      'alpn',
      'echConfigList',
      'echForceQuery',
    ]) {
      if ((candidate.credentials[key] ?? '').toLowerCase() ==
              (reference.credentials[key] ?? '').toLowerCase() &&
          candidate.credentials[key] != null) {
        score++;
      }
    }
    return score;
  }

  void _assertInScope(
    VpnNode node,
    String? requestedCountry,
    DestinationSelection selection,
  ) {
    if (selection.method != null && !selection.method!.matches(node)) {
      throw const CoreException(
        'Selected endpoint does not match the requested connection method.',
      );
    }
    if (requestedCountry == null) return;
    final resolved = LocationResolver.canonicalCountryCode(
      '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
    );
    if (resolved != requestedCountry) {
      throw const CoreException(
        'Selected endpoint does not match the requested destination country.',
      );
    }
  }
}
