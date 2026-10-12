import '../models/connection_state.dart';

class InvalidConnectionTransition implements Exception {
  const InvalidConnectionTransition(this.from, this.to);
  final ConnectionPhase from;
  final ConnectionPhase to;
  @override
  String toString() =>
      'Invalid connection transition: ${from.name} → ${to.name}';
}

class ConnectionStateMachine {
  ConnectionStateMachine([ConnectionPhase initial = ConnectionPhase.noProfile])
    : _phase = initial;

  ConnectionPhase _phase;
  ConnectionPhase get phase => _phase;

  static const _allowed = <ConnectionPhase, Set<ConnectionPhase>>{
    ConnectionPhase.noProfile: {ConnectionPhase.disconnected},
    ConnectionPhase.disconnected: {
      ConnectionPhase.preparing,
      ConnectionPhase.noProfile,
    },
    ConnectionPhase.preparing: {
      ConnectionPhase.connecting,
      ConnectionPhase.failed,
      ConnectionPhase.disconnected,
      ConnectionPhase.disconnecting,
    },
    ConnectionPhase.connecting: {
      ConnectionPhase.verifying,
      ConnectionPhase.connected,
      ConnectionPhase.reconnecting,
      ConnectionPhase.failed,
      ConnectionPhase.disconnecting,
    },
    ConnectionPhase.verifying: {
      ConnectionPhase.connected,
      ConnectionPhase.failed,
      ConnectionPhase.reconnecting,
      ConnectionPhase.disconnecting,
    },
    ConnectionPhase.connected: {
      ConnectionPhase.reconnecting,
      ConnectionPhase.disconnecting,
      ConnectionPhase.failed,
    },
    ConnectionPhase.reconnecting: {
      ConnectionPhase.connecting,
      ConnectionPhase.verifying,
      ConnectionPhase.failed,
      ConnectionPhase.disconnecting,
    },
    ConnectionPhase.disconnecting: {
      ConnectionPhase.disconnected,
      ConnectionPhase.failed,
    },
    ConnectionPhase.failed: {
      ConnectionPhase.preparing,
      ConnectionPhase.disconnected,
      ConnectionPhase.noProfile,
      ConnectionPhase.disconnecting,
    },
  };

  void transitionTo(ConnectionPhase next) {
    if (next == _phase) return;
    if (!(_allowed[_phase]?.contains(next) ?? false)) {
      throw InvalidConnectionTransition(_phase, next);
    }
    _phase = next;
  }
}
