import 'connection_state.dart';

enum ConnectionMapState {
  world,
  connecting,
  zoomingToDestination,
  connected,
  reconnecting,
  failed,
  returningToWorld,
}

ConnectionMapState mapStateFor(ConnectionPhase phase, {bool settled = false}) =>
    switch (phase) {
      ConnectionPhase.noProfile ||
      ConnectionPhase.disconnected => ConnectionMapState.world,
      ConnectionPhase.preparing ||
      ConnectionPhase.connecting ||
      ConnectionPhase.verifying => ConnectionMapState.connecting,
      ConnectionPhase.connected =>
        settled
            ? ConnectionMapState.connected
            : ConnectionMapState.zoomingToDestination,
      ConnectionPhase.reconnecting => ConnectionMapState.reconnecting,
      ConnectionPhase.disconnecting => ConnectionMapState.returningToWorld,
      ConnectionPhase.failed => ConnectionMapState.failed,
    };
