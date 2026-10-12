import 'package:flutter/material.dart';

import '../../domain/models/connection_state.dart';
import '../../domain/services/location_resolver.dart';
import 'connection_control.dart';
import '../../prototypes/responsive_globe.dart';

Duration _connectionTextDuration(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations == true
    ? Duration.zero
    : const Duration(milliseconds: 750);

/// One visual composition for map geography, verified exit label, power
/// control, and connection status. Network state remains owned by the app.
class ConnectionScene extends StatelessWidget {
  const ConnectionScene({
    required this.phase,
    required this.destination,
    required this.destinationLabel,
    required this.destinationSemantics,
    required this.connectionLabel,
    required this.actionLabel,
    required this.onPressed,
    this.onRefreshPing,
    this.refreshPingLabel = '',
    this.refreshingPing = false,
    this.failure,
    this.health,
    this.height = 350,
    this.showControls = true,
    this.showMap = true,
    super.key,
  });

  final ConnectionPhase phase;
  final DestinationLocation? destination;
  final String? destinationLabel;
  final String? destinationSemantics;
  final String connectionLabel;
  final String actionLabel;
  final VoidCallback? onPressed;
  final Future<void> Function()? onRefreshPing;
  final String refreshPingLabel;
  final bool refreshingPing;
  final String? failure;
  final String? health;
  final double height;
  final bool showControls;
  final bool showMap;

  @override
  Widget build(BuildContext context) {
    final mapHeight = showControls
        ? (height * .80).clamp(300.0, 340.0).toDouble()
        : height;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          if (phase == ConnectionPhase.connected &&
              destinationSemantics != null)
            Semantics(
              container: true,
              label: destinationSemantics,
              child: const SizedBox.shrink(),
            ),
          if (showMap)
            SizedBox(
              height: mapHeight,
              child: OverflowBox(
                minWidth: MediaQuery.sizeOf(context).width,
                maxWidth: MediaQuery.sizeOf(context).width,
                alignment: Alignment.center,
                child: ResponsiveGlobe(
                  lightMode: Theme.of(context).brightness == Brightness.light,
                  destinationTarget: _globeTarget(destination),
                  showDebugControls: false,
                ),
              ),
            ),
          if (!showMap) SizedBox(height: mapHeight),
          if (showControls)
            Expanded(
              child: ConnectionStatusPanel(
                phase: phase,
                connectionLabel: connectionLabel,
                actionLabel: actionLabel,
                onPressed: onPressed,
                failure: failure,
                health: health,
                onRefreshPing: onRefreshPing,
                refreshPingLabel: refreshPingLabel,
                refreshingPing: refreshingPing,
              ),
            ),
        ],
      ),
    );
  }
}

GlobeTarget? _globeTarget(DestinationLocation? location) {
  if (location == null || !location.hasCoordinates) return null;
  final name = location.country.isEmpty
      ? location.countryCode
      : location.country;
  return GlobeTarget(name, location.latitude!, location.longitude!);
}

/// Connection control and state text can be anchored above the fixed usage
/// cards while the map remains a large, independently scrolling scene.
class ConnectionStatusPanel extends StatelessWidget {
  const ConnectionStatusPanel({
    required this.phase,
    required this.connectionLabel,
    required this.actionLabel,
    required this.onPressed,
    this.onRefreshPing,
    this.refreshPingLabel = '',
    this.refreshingPing = false,
    this.failure,
    this.health,
    super.key,
  });

  final ConnectionPhase phase;
  final String connectionLabel;
  final String actionLabel;
  final VoidCallback? onPressed;
  final Future<void> Function()? onRefreshPing;
  final String refreshPingLabel;
  final bool refreshingPing;
  final String? failure;
  final String? health;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConnectionControl(
          phase: phase,
          label: connectionLabel,
          actionLabel: actionLabel,
          onPressed: onPressed,
        ),
        const SizedBox(height: 1),
        SizedBox(
          height: 74,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: _connectionTextDuration(context),
                transitionBuilder: (child, animation) => SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(0, .22),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: Text(
                  connectionLabel,
                  key: ValueKey('$phase-$connectionLabel'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .1,
                    color: phase == ConnectionPhase.failed
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                ),
              ),
              if (phase == ConnectionPhase.connected && health != null)
                AnimatedSwitcher(
                  duration: _connectionTextDuration(context),
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  // Do not keep the previous ping visible while the fresh
                  // destination measurement fades in.
                  layoutBuilder: (currentChild, previousChildren) =>
                      currentChild ?? const SizedBox.shrink(),
                  child: Padding(
                    key: ValueKey('health-$health'),
                    padding: const EdgeInsets.only(top: 2),
                    child: onRefreshPing == null
                        ? _healthText(context)
                        : Tooltip(
                            message: refreshPingLabel,
                            child: Semantics(
                              button: true,
                              label: '$health. $refreshPingLabel',
                              enabled: !refreshingPing,
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  key: const ValueKey(
                                    'refresh-connection-ping',
                                  ),
                                  borderRadius: BorderRadius.circular(18),
                                  onTap: refreshingPing ? null : onRefreshPing,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _healthText(context),
                                        const SizedBox(width: 6),
                                        AnimatedSwitcher(
                                          duration: _connectionTextDuration(
                                            context,
                                          ),
                                          child: refreshingPing
                                              ? SizedBox(
                                                  key: const ValueKey(
                                                    'ping-loading',
                                                  ),
                                                  width: 14,
                                                  height: 14,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Theme.of(
                                                          context,
                                                        ).colorScheme.primary,
                                                      ),
                                                )
                                              : Icon(
                                                  Icons.refresh_rounded,
                                                  key: const ValueKey(
                                                    'ping-refresh-icon',
                                                  ),
                                                  size: 16,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              if (phase == ConnectionPhase.disconnected && onPressed != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    actionLabel,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (phase == ConnectionPhase.failed && failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    failure!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _healthText(BuildContext context) => Text(
    health!,
    key: const ValueKey('connection-metrics'),
    textAlign: TextAlign.center,
    style: Theme.of(context).textTheme.titleSmall?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: .1,
    ),
  );
}
