import 'dart:convert';

import '../models/vpn_node.dart';

enum RecoveryPhase {
  idle,
  tryingDirect,
  directFailed,
  tryingUserNode,
  userNodeFailed,
  tryingRecoveryPool,
  recoverySucceeded,
  recoveryFailed,
  validatingSubscription,
  updatingCache,
  completed,
}

enum RecoveryRouteKind { direct, cachedUserNode, internalRecovery }

class RecoveryRoute {
  const RecoveryRoute(this.kind, {this.nodeId, this.priority = 0});
  final RecoveryRouteKind kind;
  final String? nodeId;
  final int priority;
}

class RecoveryEndpoint {
  const RecoveryEndpoint({
    required this.id,
    required this.uri,
    this.priority = 0,
  });
  final String id;
  final Uri uri;
  final int priority;
}

class ControlPlaneResponse {
  const ControlPlaneResponse({required this.body, required this.headers});
  final String body;
  final Map<String, String> headers;
}

abstract interface class ControlPlaneTransport {
  /// Must issue the actual HTTP/TLS subscription request through [route].
  Future<ControlPlaneResponse> fetch(Uri subscriptionUri, RecoveryRoute route);
}

class ControlPlaneRecovery {
  ControlPlaneRecovery(this._transport);
  final ControlPlaneTransport _transport;
  RecoveryPhase phase = RecoveryPhase.idle;

  Future<ControlPlaneResponse> refresh({
    required Uri subscriptionUri,
    required List<VpnNode> cachedNodes,
    required String? lastHealthyNodeId,
    required List<RecoveryEndpoint> recoveryPool,
  }) async {
    if (subscriptionUri.scheme != 'https' || subscriptionUri.host.isEmpty) {
      throw ArgumentError.value(
        subscriptionUri,
        'subscriptionUri',
        'An HTTPS subscription URI is required.',
      );
    }
    for (final endpoint in recoveryPool) {
      if (endpoint.uri.scheme != 'https' ||
          endpoint.uri.host.isEmpty ||
          endpoint.uri.userInfo.isNotEmpty ||
          endpoint.uri.hasFragment) {
        throw const FormatException('Recovery pool endpoint is invalid.');
      }
    }
    phase = RecoveryPhase.idle;
    final orderedRecoveryPool = recoveryPool.toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final routes = <RecoveryRoute>[
      const RecoveryRoute(RecoveryRouteKind.direct),
      ..._orderedUserNodes(cachedNodes, lastHealthyNodeId),
      ...orderedRecoveryPool.map(
        (endpoint) => RecoveryRoute(
          RecoveryRouteKind.internalRecovery,
          nodeId: endpoint.id,
          priority: endpoint.priority,
        ),
      ),
    ];

    for (final route in routes) {
      phase = switch (route.kind) {
        RecoveryRouteKind.direct => RecoveryPhase.tryingDirect,
        RecoveryRouteKind.cachedUserNode => RecoveryPhase.tryingUserNode,
        RecoveryRouteKind.internalRecovery => RecoveryPhase.tryingRecoveryPool,
      };
      try {
        final response = await _transport.fetch(subscriptionUri, route);
        phase = RecoveryPhase.recoverySucceeded;
        return response;
      } catch (_) {
        phase = switch (route.kind) {
          RecoveryRouteKind.direct => RecoveryPhase.directFailed,
          RecoveryRouteKind.cachedUserNode => RecoveryPhase.userNodeFailed,
          RecoveryRouteKind.internalRecovery => RecoveryPhase.recoveryFailed,
        };
      }
    }
    phase = RecoveryPhase.recoveryFailed;
    throw StateError('All subscription routes failed.');
  }

  List<RecoveryRoute> _orderedUserNodes(
    List<VpnNode> nodes,
    String? lastHealthy,
  ) {
    final usable =
        nodes.where((node) => node.enabled && node.id != lastHealthy).toList()
          ..sort((a, b) {
            final aScore = a.health == NodeHealth.healthy ? 0 : 1;
            final bScore = b.health == NodeHealth.healthy ? 0 : 1;
            return aScore.compareTo(bScore);
          });
    return [
      if (lastHealthy != null &&
          nodes.any((node) => node.id == lastHealthy && node.enabled))
        RecoveryRoute(RecoveryRouteKind.cachedUserNode, nodeId: lastHealthy),
      ...usable.map(
        (node) =>
            RecoveryRoute(RecoveryRouteKind.cachedUserNode, nodeId: node.id),
      ),
    ];
  }
}

abstract interface class RecoveryManifestVerifier {
  Future<bool> verify(String manifestPayload, String signature);
}

class RecoveryManifest {
  const RecoveryManifest({
    required this.version,
    required this.issuedAt,
    required this.expiresAt,
    required this.destinationAllowlist,
    required this.endpoints,
  });

  final int version;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final Set<String> destinationAllowlist;
  final List<RecoveryEndpoint> endpoints;

  Map<String, Object?> toJson() => {
    'version': version,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'destinationAllowlist': destinationAllowlist.toList()..sort(),
    'endpoints': [
      for (final endpoint in endpoints)
        {
          'id': endpoint.id,
          'url': endpoint.uri.toString(),
          'priority': endpoint.priority,
        },
    ],
  };
}

abstract interface class RecoveryManifestStore {
  /// Replace the stored snapshot with one already verified in full.
  Future<void> replace(RecoveryManifest manifest);
}

/// Rejects invalid candidates; callers may persist a replacement only after
/// this returns true. The pinned-key verifier is supplied by the Android crypto
/// adapter and is intentionally not permissive when no key is configured.
Future<RecoveryManifest> validateRecoveryManifest({
  required String payload,
  required String signature,
  required RecoveryManifestVerifier verifier,
  required DateTime now,
}) async {
  if (utf8.encode(payload).length > 64 * 1024 ||
      signature.isEmpty ||
      signature.length > 2048) {
    throw const FormatException('Recovery manifest exceeds its size limit.');
  }
  if (!await verifier.verify(payload, signature)) {
    throw const FormatException('Recovery manifest signature is invalid.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    throw const FormatException('Recovery manifest JSON is invalid.');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Recovery manifest must be a JSON object.');
  }
  final version = decoded['version'];
  final issuedAt = DateTime.tryParse(decoded['issuedAt']?.toString() ?? '');
  final expiry = DateTime.tryParse(decoded['expiresAt']?.toString() ?? '');
  if (version != 1 ||
      issuedAt == null ||
      expiry == null ||
      !expiry.isAfter(now) ||
      issuedAt.isAfter(now.add(const Duration(minutes: 5))) ||
      !expiry.isAfter(issuedAt) ||
      expiry.difference(issuedAt) > const Duration(days: 30)) {
    throw const FormatException('Recovery manifest is expired or invalid.');
  }
  final allowedRaw = decoded['destinationAllowlist'];
  final endpointsRaw = decoded['endpoints'];
  if (allowedRaw is! List ||
      allowedRaw.isEmpty ||
      endpointsRaw is! List ||
      endpointsRaw.isEmpty ||
      endpointsRaw.length > 16) {
    throw const FormatException('Recovery manifest structure is invalid.');
  }
  final allowed = <String>{};
  for (final item in allowedRaw) {
    if (item is! String) {
      throw const FormatException('Recovery destination allowlist is invalid.');
    }
    final host = item.toLowerCase();
    if (!_isValidRecoveryHost(host)) {
      throw const FormatException('Recovery destination allowlist is invalid.');
    }
    allowed.add(host);
  }
  if (allowed.length != allowedRaw.length) {
    throw const FormatException(
      'Recovery destination allowlist has duplicates.',
    );
  }
  final endpoints = <RecoveryEndpoint>[];
  final ids = <String>{};
  for (final item in endpointsRaw) {
    if (item is! Map<String, dynamic>) {
      throw const FormatException('Recovery endpoint entry is invalid.');
    }
    final id = item['id'];
    final rawUri = item['url'];
    final priority = item['priority'] ?? 0;
    final uri = rawUri is String ? Uri.tryParse(rawUri) : null;
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id) ||
        !ids.add(id) ||
        priority is! int ||
        priority < 0 ||
        priority > 10000 ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !_isValidRecoveryHost(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !_hostIsAllowed(uri.host.toLowerCase(), allowed)) {
      throw const FormatException(
        'Recovery endpoint is outside the signed allowlist.',
      );
    }
    endpoints.add(RecoveryEndpoint(id: id, uri: uri, priority: priority));
  }
  return RecoveryManifest(
    version: version as int,
    issuedAt: issuedAt.toUtc(),
    expiresAt: expiry.toUtc(),
    destinationAllowlist: Set.unmodifiable(allowed),
    endpoints: List.unmodifiable(endpoints),
  );
}

/// Verify the complete signed candidate before atomically replacing the cache.
Future<RecoveryManifest> verifyAndReplaceRecoveryManifest({
  required String payload,
  required String signature,
  required RecoveryManifestVerifier verifier,
  required RecoveryManifestStore store,
  required DateTime now,
}) async {
  final verified = await validateRecoveryManifest(
    payload: payload,
    signature: signature,
    verifier: verifier,
    now: now,
  );
  await store.replace(verified);
  return verified;
}

bool _hostIsAllowed(String host, Set<String> allowlist) =>
    allowlist.any((allowed) => host == allowed || host.endsWith('.$allowed'));

bool _isValidRecoveryHost(String host) {
  if (host.length > 253 || host.startsWith('.') || host.endsWith('.')) {
    return false;
  }
  final labels = host.split('.');
  if (labels.length < 2) return false;
  return labels.every(
    (label) =>
        label.length <= 63 &&
        RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
  );
}
