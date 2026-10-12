import 'dart:convert';

enum ProxyProtocol { vless, vmess, trojan, shadowsocks, hysteria, unknown }

enum NodeHealth { unknown, healthy, degraded, unhealthy }

enum RuntimeHealthState {
  unknown,
  healthy,
  nodeSpecificDegraded,
  globalNetworkDegraded,
  hardFailure,
  dead,
}

enum LocationSource { subscription, database, serverMetadata, unknown }

enum ProxyCoreKind { xray }

/// A normalized node. [credentials] must never be included in logs or UI.
class VpnNode {
  VpnNode({
    required this.id,
    required this.subscriptionId,
    required this.name,
    required this.protocol,
    required this.host,
    required this.port,
    this.credentials = const {},
    this.xrayOutbound = const {},
    this.sourceMetadata = const {},
    this.importWarnings = const [],
    this.transport = 'tcp',
    this.country,
    this.countryCode,
    this.city,
    this.latitude,
    this.longitude,
    this.locationSource = LocationSource.unknown,
    this.locationConfidence = 0,
    this.sni,
    this.fingerprint,
    this.enabled = true,
    this.latency,
    this.connectionEstablishmentTime,
    this.lastSuccess,
    this.lastFailure,
    this.successCount = 0,
    this.failureCount = 0,
    this.stabilityScore = 0,
    this.health = NodeHealth.unknown,
    this.lastProbe,
    this.last5Pings = const [],
    this.baselinePing,
    this.consecutiveFailures = 0,
    this.runtimeState = RuntimeHealthState.unknown,
  });

  final String id;
  final String subscriptionId;
  final String name;
  final ProxyProtocol protocol;
  final String host;
  final int port;
  final Map<String, String> credentials;

  /// Structured connection metadata; encrypted with the subscription cache.
  /// Never include this, or [sourceMetadata], in logs or UI.
  final Map<String, Object?> xrayOutbound;
  final Map<String, Object?> sourceMetadata;

  /// Redacted field names/reasons only, never values or source links.
  final List<String> importWarnings;
  final String transport;
  final String? country;
  final String? countryCode;
  final String? city;
  final double? latitude;
  final double? longitude;
  final LocationSource locationSource;
  final double locationConfidence;
  final String? sni;
  final String? fingerprint;
  final bool enabled;
  final Duration? latency;
  final Duration? connectionEstablishmentTime;
  final DateTime? lastSuccess;
  final DateTime? lastFailure;
  final int successCount;
  final int failureCount;
  final double stabilityScore;
  final NodeHealth health;
  final DateTime? lastProbe;
  final List<int> last5Pings;
  final Duration? baselinePing;
  final int consecutiveFailures;
  RuntimeHealthState runtimeState;

  /// The only latency allowed to drive UI, scoring, health, and history.
  /// It is populated from a warm HTTP first-byte measurement through Xray.
  Duration? get authoritativeLatency => latency;

  String get safeDescription => '${protocol.name} node at $host:$port';

  Map<String, Object?> toJson() => {
    'id': id,
    'subscriptionId': subscriptionId,
    'name': name,
    'protocol': protocol.name,
    'host': host,
    'port': port,
    'credentials': credentials,
    'xrayOutbound': xrayOutbound,
    'sourceMetadata': sourceMetadata,
    'importWarnings': importWarnings,
    'transport': transport,
    'country': country,
    'countryCode': countryCode,
    'city': city,
    'latitude': latitude,
    'longitude': longitude,
    'locationSource': locationSource.name,
    'locationConfidence': locationConfidence,
    'sni': sni,
    'fingerprint': fingerprint,
    'enabled': enabled,
    'latencyMs': latency?.inMilliseconds,
    'connectionEstablishmentMs': connectionEstablishmentTime?.inMilliseconds,
    'lastSuccess': lastSuccess?.toIso8601String(),
    'lastFailure': lastFailure?.toIso8601String(),
    'successCount': successCount,
    'failureCount': failureCount,
    'stabilityScore': stabilityScore,
    'health': health.name,
    'lastProbe': lastProbe?.toIso8601String(),
    'last5Pings': last5Pings,
    'baselinePingMs': baselinePing?.inMilliseconds,
    'consecutiveFailures': consecutiveFailures,
    'runtimeState': runtimeState.name,
  };

  factory VpnNode.fromJson(Map<String, Object?> json) {
    final protocol = ProxyProtocol.values.byName(json['protocol']! as String);
    final credentials =
        (json['credentials'] as Map?)?.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        ) ??
        <String, String>{};
    _migrateLegacySecurity(credentials, protocol);
    return VpnNode(
      id: json['id']! as String,
      subscriptionId: json['subscriptionId']! as String,
      name: json['name']! as String,
      protocol: protocol,
      host: json['host']! as String,
      port: json['port']! as int,
      credentials: credentials,
      xrayOutbound: Map<String, Object?>.from(
        json['xrayOutbound'] as Map? ?? const {},
      ),
      sourceMetadata: Map<String, Object?>.from(
        json['sourceMetadata'] as Map? ?? const {},
      ),
      importWarnings: (json['importWarnings'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      transport: json['transport'] as String? ?? 'tcp',
      country: json['country'] as String?,
      countryCode: json['countryCode'] as String?,
      city: json['city'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      locationSource: LocationSource.values.byName(
        json['locationSource'] as String? ?? 'unknown',
      ),
      locationConfidence: (json['locationConfidence'] as num?)?.toDouble() ?? 0,
      sni: json['sni'] as String?,
      fingerprint: json['fingerprint'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      latency: (json['latencyMs'] as num?) == null
          ? null
          : Duration(milliseconds: (json['latencyMs'] as num).round()),
      connectionEstablishmentTime:
          (json['connectionEstablishmentMs'] as num?) == null
          ? null
          : Duration(
              milliseconds: (json['connectionEstablishmentMs'] as num).round(),
            ),
      lastSuccess: _date(json['lastSuccess']),
      lastFailure: _date(json['lastFailure']),
      successCount: json['successCount'] as int? ?? 0,
      failureCount: json['failureCount'] as int? ?? 0,
      stabilityScore: (json['stabilityScore'] as num?)?.toDouble() ?? 0,
      health: NodeHealth.values.byName(json['health'] as String? ?? 'unknown'),
      lastProbe: _date(json['lastProbe']),
      last5Pings: (json['last5Pings'] is List)
          ? (json['last5Pings'] as List)
                .whereType<num>()
                .map((value) => value.round())
                .take(5)
                .toList(growable: false)
          : const [],
      baselinePing: (json['baselinePingMs'] as num?) == null
          ? null
          : Duration(milliseconds: (json['baselinePingMs'] as num).round()),
      consecutiveFailures: json['consecutiveFailures'] as int? ?? 0,
      runtimeState: RuntimeHealthState.values.byName(
        json['runtimeState'] as String? ??
            ((json['deadForCycle'] as bool? ?? false) ? 'dead' : 'unknown'),
      ),
    );
  }

  static void _migrateLegacySecurity(
    Map<String, String> credentials,
    ProxyProtocol protocol,
  ) {
    if (protocol == ProxyProtocol.shadowsocks ||
        credentials.containsKey('tlsSecurity')) {
      return;
    }
    final legacySecurity = credentials['security'];
    if (protocol == ProxyProtocol.vmess) {
      credentials['tlsSecurity'] = legacySecurity == 'tls' ? 'tls' : 'none';
      if (legacySecurity == 'tls') credentials['security'] = 'auto';
      return;
    }
    credentials['tlsSecurity'] = switch (legacySecurity) {
      'tls' || 'reality' => legacySecurity!,
      _ => 'none',
    };
    credentials.remove('security');
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

String encodeNodes(Iterable<VpnNode> nodes) => jsonEncode({
  'schemaVersion': 2,
  'nodes': nodes.map((node) => node.toJson()).toList(growable: false),
});

List<VpnNode> decodeNodes(String source) {
  final decoded = jsonDecode(source);
  final List<Object?> rows;
  if (decoded is List<Object?>) {
    // Version 1 stored a bare node list. fromJson migrates legacy security fields.
    rows = decoded;
  } else if (decoded is Map) {
    final version = decoded['schemaVersion'];
    final nodes = decoded['nodes'];
    if (version != 2 || nodes is! List<Object?>) {
      throw const FormatException('Unsupported subscription cache schema.');
    }
    rows = nodes;
  } else {
    throw const FormatException('Subscription cache is not a node list.');
  }
  return rows
      .map((row) => VpnNode.fromJson(Map<String, Object?>.from(row! as Map)))
      .toList(growable: false);
}
