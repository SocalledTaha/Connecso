import 'dart:developer' as developer;

import '../models/connection_state.dart';
import '../models/resolved_endpoint.dart';
import '../models/vpn_node.dart';
import 'connection_state_machine.dart';
import 'connect_trace.dart';
import 'core_manager.dart';
import 'endpoint_resolver.dart';
import 'location_resolver.dart';
import 'split_tunnel_policy.dart';
import 'structured_logger.dart';

abstract interface class TunnelAdapter {
  Future<void> requestPermission();
  Future<void> start(
    ProxyCore core,
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  });
  Future<void> stop();
  Future<bool> verifyUsableConnectivity();
  Future<CoreStats> readStats();
}

class ConnectionCancelled implements Exception {
  const ConnectionCancelled();
}

/// Starts ranked endpoints produced by [EndpointResolver], advancing through
/// reachable candidates and priority tiers only when an actual tunnel attempt
/// fails for an endpoint-specific, retryable reason.
class ConnectionManager {
  ConnectionManager({
    required TunnelAdapter tunnel,
    required CoreManager cores,
    Future<void> Function(VpnNode node, Duration duration)? recordNodeFailure,
    void Function(ConnectionPhase phase)? onPhaseChanged,
    void Function(VpnNode node)? onNodeSelected,
  }) : _tunnel = tunnel,
       _cores = cores,
       _recordNodeFailure = recordNodeFailure,
       _onPhaseChanged = onPhaseChanged,
       _onNodeSelected = onNodeSelected;

  final TunnelAdapter _tunnel;
  final CoreManager _cores;
  final Future<void> Function(VpnNode node, Duration duration)?
  _recordNodeFailure;
  final void Function(ConnectionPhase phase)? _onPhaseChanged;
  final void Function(VpnNode node)? _onNodeSelected;
  final _logger = StructuredLogger();
  final machine = ConnectionStateMachine(ConnectionPhase.disconnected);
  ConnectionStatus get status => ConnectionStatus(phase: machine.phase);
  Duration? get lastConnectionEstablishmentTime =>
      _lastConnectionEstablishmentTime;
  Duration? _lastConnectionEstablishmentTime;
  bool _connectCancelled = false;
  Stopwatch? _connectTrace;

  void _trace(String event, [String details = '']) {
    final elapsed = _connectTrace?.elapsedMilliseconds ?? 0;
    final message = '+${elapsed}ms $event${details.isEmpty ? '' : ' $details'}';
    ConnectTrace.emit(message);
    developer.log(message, name: 'CONNECSO_CONNECT_TRACE');
  }

  void resetSubscriptionCycle(Iterable<VpnNode> nodes) {
    for (final node in nodes) {
      node.runtimeState = RuntimeHealthState.unknown;
    }
  }

  void recordBackgroundProbe(VpnNode node, {required bool reachable}) {
    node.runtimeState = reachable
        ? RuntimeHealthState.healthy
        : RuntimeHealthState.hardFailure;
  }

  void restoreConnectedSession() {
    if (machine.phase == ConnectionPhase.noProfile ||
        machine.phase == ConnectionPhase.failed) {
      _transitionTo(ConnectionPhase.disconnected);
    }
    if (machine.phase == ConnectionPhase.disconnected) {
      _transitionTo(ConnectionPhase.preparing);
      _transitionTo(ConnectionPhase.connecting);
      _transitionTo(ConnectionPhase.verifying);
    }
    if (machine.phase == ConnectionPhase.verifying)
      _transitionTo(ConnectionPhase.connected);
  }

  void restoreDisconnectedSession() {
    if (machine.phase == ConnectionPhase.connected) {
      _transitionTo(ConnectionPhase.disconnecting);
      _transitionTo(ConnectionPhase.disconnected);
    } else if (machine.phase == ConnectionPhase.failed) {
      _transitionTo(ConnectionPhase.disconnected);
    }
  }

  void _transitionTo(ConnectionPhase phase) {
    machine.transitionTo(phase);
    _onPhaseChanged?.call(phase);
  }

  Future<VpnNode> connect(
    ResolvedEndpoint endpoint, {
    required SplitTunnelPolicy splitTunnelPolicy,
  }) async {
    _connectCancelled = false;
    _connectTrace = Stopwatch()..start();
    final node = endpoint.node;
    final resolvedLocation = const LocationResolver().resolve(node);
    final traceCountry = resolvedLocation?.countryCode.isNotEmpty == true
        ? resolvedLocation!.countryCode
        : (node.countryCode ?? node.country ?? 'unknown');
    _trace(
      'endpoint_resolved',
      'node=${node.id} host=${node.host} port=${node.port} '
          'country=$traceCountry '
          'protocol=${node.protocol.name} transport=${node.transport} '
          'sni=${node.sni ?? 'none'} fingerprint=${node.fingerprint ?? 'none'} '
          'alpn=${node.credentials['alpn'] ?? 'default'} '
          'reason=${endpoint.reason.name}',
    );
    if (machine.phase == ConnectionPhase.failed)
      _transitionTo(ConnectionPhase.disconnected);
    if (machine.phase != ConnectionPhase.disconnected) {
      throw StateError('A clean disconnected session is required.');
    }
    _transitionTo(ConnectionPhase.preparing);
    final stopwatch = Stopwatch()..start();
    try {
      _trace('core_initialize_start');
      await _cores.initialize();
      _trace('core_initialize_complete');
      _throwIfConnectCancelled();
      final core = _cores.choose(node);
      _trace(
        'core_selected',
        'available=${core != null} protocol=${node.protocol.name}',
      );
      if (core == null)
        throw const CoreException('No compatible VPN core is installed.');
      _onNodeSelected?.call(node);
      _trace('vpn_permission_request_start');
      await _tunnel.requestPermission();
      _trace('vpn_permission_granted');
      _throwIfConnectCancelled();
      _transitionTo(ConnectionPhase.connecting);
      _trace(
        'connection_start_requested',
        'node=${node.id} protocol=${node.protocol.name} transport=${node.transport}',
      );
      await _tunnel.start(core, node, splitTunnelPolicy: splitTunnelPolicy);
      _trace('tunnel_start_completed');
      _throwIfConnectCancelled();
      _transitionTo(ConnectionPhase.verifying);
      _trace('dataplane_verification_start');
      final verified = await _tunnel.verifyUsableConnectivity();
      _trace('dataplane_verification_complete', 'verified=$verified');
      if (!verified) {
        throw const CoreException(
          'Connection could not be verified through the VPN dataplane.',
          retryable: true,
        );
      }
      _trace('dataplane_verified');
      _transitionTo(ConnectionPhase.connected);
      _lastConnectionEstablishmentTime = stopwatch.elapsed;
      node.runtimeState = RuntimeHealthState.healthy;
      _logger.record(
        category: LogCategory.vpn,
        severity: LogSeverity.info,
        event: 'connection.verified',
        fields: {
          'durationMs': stopwatch.elapsedMilliseconds,
          'protocol': node.protocol.name,
          'selectionReason': endpoint.reason.name,
        },
      );
      return _withSuccessfulProbe(
        node,
        node.authoritativeLatency,
        stopwatch.elapsed,
      );
    } catch (error) {
      final safeFailure = error is CoreException
          ? error.message
          : error.runtimeType.toString();
      _trace(
        'connection_attempt_threw',
        'type=${error.runtimeType} detail=${safeFailure.replaceAll(RegExp(r'\s+'), ' ')}',
      );
      await _handleConnectionFailure(node, stopwatch.elapsed, error);
      if (error is ConnectionCancelled || _connectCancelled)
        throw const ConnectionCancelled();
      rethrow;
    } finally {
      _connectCancelled = false;
    }
  }

  Future<VpnNode> connectWithFailover({
    required Future<EndpointResolution> Function(Set<String> excludedNodeIds)
    resolve,
    required SplitTunnelPolicy splitTunnelPolicy,
    bool reconnect = false,
  }) async {
    final excluded = <String>{};
    Object? lastConnectionError;
    var reconnectCurrent = reconnect;
    var attemptNumber = 0;

    while (true) {
      late final EndpointResolution resolution;
      try {
        resolution = await resolve(Set.unmodifiable(excluded));
      } catch (_) {
        if (lastConnectionError != null) throw lastConnectionError;
        rethrow;
      }
      excluded.addAll(resolution.checkedNodeIds);
      if (resolution.endpoints.isEmpty) {
        if (lastConnectionError != null) throw lastConnectionError;
        throw const CoreException(
          'No reachable endpoint matched the selection.',
        );
      }

      for (final endpoint in resolution.endpoints) {
        attemptNumber++;
        try {
          return reconnectCurrent
              ? await this.reconnect(
                  endpoint,
                  splitTunnelPolicy: splitTunnelPolicy,
                )
              : await connect(endpoint, splitTunnelPolicy: splitTunnelPolicy);
        } catch (error) {
          if (error is ConnectionCancelled) rethrow;
          if (error is! CoreException || !error.retryable) rethrow;
          lastConnectionError = error;
          reconnectCurrent = false;
          final nextExists =
              attemptNumber < resolution.endpoints.length ||
              resolution.checkedNodeIds.isNotEmpty;
          ConnectTrace.emit(
            'connection_candidate_failed node=${endpoint.node.id} '
            'retryable=true attempt=$attemptNumber nextCandidate=$nextExists',
          );
          developer.log(
            'connection_candidate_failed node=${endpoint.node.id} '
            'retryable=true nextCandidate=$nextExists',
            name: 'CONNECSO/Resolver',
          );
        }
      }
      // The next resolution excludes every node examined in this tier. It
      // therefore advances to the next tier only after this tier's viable
      // candidates have all failed during tunnel start or verification.
    }
  }

  Future<VpnNode> reconnect(
    ResolvedEndpoint endpoint, {
    required SplitTunnelPolicy splitTunnelPolicy,
  }) async {
    if (machine.phase == ConnectionPhase.connected) {
      _transitionTo(ConnectionPhase.disconnecting);
      try {
        await _tunnel.stop();
      } finally {
        _transitionTo(ConnectionPhase.disconnected);
      }
    } else if (machine.phase == ConnectionPhase.failed) {
      _transitionTo(ConnectionPhase.disconnected);
    }
    return connect(endpoint, splitTunnelPolicy: splitTunnelPolicy);
  }

  Future<void> _handleConnectionFailure(
    VpnNode node,
    Duration duration,
    Object error,
  ) async {
    node.runtimeState = RuntimeHealthState.hardFailure;
    try {
      await _recordNodeFailure?.call(node, duration);
    } catch (_) {}
    Object? cleanupError;
    try {
      await _tunnel.stop();
    } catch (failure) {
      cleanupError = failure;
    }
    _logger.record(
      category: LogCategory.vpn,
      severity: LogSeverity.warning,
      event: 'connection.attempt_failed',
      fields: {'failureType': error.runtimeType.toString()},
    );
    if (error is ConnectionCancelled || _connectCancelled) {
      if (machine.phase != ConnectionPhase.disconnected) {
        if (machine.phase != ConnectionPhase.disconnecting)
          _transitionTo(ConnectionPhase.disconnecting);
        _transitionTo(ConnectionPhase.disconnected);
      }
    } else if (machine.phase != ConnectionPhase.failed) {
      _transitionTo(ConnectionPhase.failed);
    }
    if (cleanupError != null) {
      _logger.record(
        category: LogCategory.vpn,
        severity: LogSeverity.error,
        event: 'connection.failed_attempt_cleanup_failed',
        fields: {'failureType': cleanupError.runtimeType.toString()},
      );
      throw const CoreException(
        'VPN cleanup failed after a connection attempt.',
      );
    }
  }

  Future<void> cancelConnect() async {
    if (!{
      ConnectionPhase.preparing,
      ConnectionPhase.connecting,
      ConnectionPhase.verifying,
      ConnectionPhase.reconnecting,
    }.contains(machine.phase))
      return;
    _connectCancelled = true;
    if (machine.phase != ConnectionPhase.disconnecting)
      _transitionTo(ConnectionPhase.disconnecting);
    try {
      await _tunnel.stop();
    } finally {
      if (machine.phase == ConnectionPhase.disconnecting)
        _transitionTo(ConnectionPhase.disconnected);
    }
  }

  void _throwIfConnectCancelled() {
    if (_connectCancelled) throw const ConnectionCancelled();
  }

  VpnNode _withSuccessfulProbe(
    VpnNode node,
    Duration? latency,
    Duration establishmentTime,
  ) {
    if (latency == null || latency.inMilliseconds <= 0) return node;
    final observations = node.successCount + node.failureCount;
    final successes = node.successCount + 1;
    final stability =
        ((node.stabilityScore * observations) + 1) / (observations + 1);
    final checkedAt = DateTime.now().toUtc();
    final samples = [...node.last5Pings, latency.inMilliseconds];
    final last5 = samples.length > 5
        ? samples.sublist(samples.length - 5)
        : samples;
    final baseline = node.baselinePing ?? latency;
    return VpnNode.fromJson({
      ...node.toJson(),
      'latencyMs': latency.inMilliseconds,
      'lastProbe': checkedAt.toIso8601String(),
      'lastSuccess': checkedAt.toIso8601String(),
      'successCount': successes,
      'stabilityScore': stability,
      'health': latency <= const Duration(milliseconds: 1500)
          ? NodeHealth.healthy.name
          : NodeHealth.degraded.name,
      'connectionEstablishmentMs': establishmentTime.inMilliseconds,
      'last5Pings': last5,
      'baselinePingMs': baseline.inMilliseconds,
      'consecutiveFailures': 0,
      'runtimeState': RuntimeHealthState.healthy.name,
    });
  }

  Future<void> disconnect() async {
    // Always send the stop command, even when Flutter believes the session is
    // disconnected. The Android service is a separate process and may still
    // own a TUN/core after a missed result broadcast or activity recreation.
    final wasDisconnected = machine.phase == ConnectionPhase.disconnected;
    if (!wasDisconnected && machine.phase != ConnectionPhase.disconnecting)
      _transitionTo(ConnectionPhase.disconnecting);
    try {
      await _tunnel.stop();
      if (!wasDisconnected) _transitionTo(ConnectionPhase.disconnected);
    } catch (_) {
      if (!wasDisconnected) _transitionTo(ConnectionPhase.failed);
      rethrow;
    }
  }
}
