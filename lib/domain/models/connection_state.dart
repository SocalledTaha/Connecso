enum ConnectionPhase {
  noProfile,
  disconnected,
  preparing,
  connecting,
  verifying,
  connected,
  reconnecting,
  disconnecting,
  failed,
}

enum FailureCategory {
  network,
  node,
  configuration,
  core,
  verification,
  permission,
  unknown,
}

class ConnectionStatus {
  const ConnectionStatus({
    required this.phase,
    this.activeNode,
    this.latency,
    this.stabilityScore,
    this.failure,
    this.failureCategory,
    this.sessionStartedAt,
  });

  final ConnectionPhase phase;
  final String? activeNode;
  final Duration? latency;
  final double? stabilityScore;
  final String? failure;
  final FailureCategory? failureCategory;
  final DateTime? sessionStartedAt;

  bool get isVerifiedConnected => phase == ConnectionPhase.connected;

  /// Do not include credentials, subscription URLs, or raw configuration in
  /// diagnostics. Callers may safely attach this value to redacted logs.
  Map<String, Object?> toSafeLogMap() => {
    'phase': phase.name,
    if (activeNode != null) 'activeNode': activeNode,
    if (latency != null) 'latencyMs': latency!.inMilliseconds,
    if (stabilityScore != null) 'stabilityScore': stabilityScore,
    if (failureCategory != null) 'failureCategory': failureCategory!.name,
    if (sessionStartedAt != null)
      'sessionStartedAt': sessionStartedAt!.toUtc().toIso8601String(),
  };
}
