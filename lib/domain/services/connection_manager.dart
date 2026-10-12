import 'dart:developer' as developer;

import '../models/connection_state.dart';
import '../models/resolved_endpoint.dart';
import '../models/vpn_node.dart';
import 'connection_state_machine.dart';
import 'connect_trace.dart';
import 'core_manager.dart';
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

/// Starts one endpoint that has already been selected by [EndpointResolver].
/// This layer deliberately has no country, destination mode, tier or scoring logic.
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
      await _cores.initialize();
      _throwIfConnectCancelled();
      final core = _cores.choose(node);
      if (core == null)
        throw const CoreException('No compatible VPN core is installed.');
      _onNodeSelected?.call(node);
      await _tunnel.requestPermission();
      _throwIfConnectCancelled();
      _transitionTo(ConnectionPhase.connecting);
      _trace(
        'connection_start_requested',
        'node=${node.id} protocol=${node.protocol.name} transport=${node.transport}',
      );
      await _tunnel.start(core, node, splitTunnelPolicy: splitTunnelPolicy);
      _throwIfConnectCancelled();
      _transitionTo(ConnectionPhase.verifying);
      _trace('dataplane_verification_start');
      if (!await _tunnel.verifyUsableConnectivity()) {
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
      await _handleConnectionFailure(node, stopwatch.elapsed, error);
      if (error is ConnectionCancelled || _connectCancelled)
        throw const ConnectionCancelled();
      rethrow;
    } finally {
      _connectCancelled = false;
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
    try {
      await _tunnel.stop();
    } catch (_) {}
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
