import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

import '../../domain/models/vpn_node.dart';
import '../../domain/services/usage_service.dart';
import '../parsers/subscription_metadata.dart';
import '../parsers/subscription_parser.dart';
import 'subscription_cache.dart';

class SubscriptionRefreshResult {
  const SubscriptionRefreshResult({
    required this.nodes,
    required this.quota,
    this.profileTitle,
    this.accountEmail,
    this.supportUrl,
    this.profileUrl,
    this.announcement,
  });

  final List<VpnNode> nodes;
  final QuotaSnapshot quota;
  final String? profileTitle;
  final String? accountEmail;
  final String? supportUrl;
  final String? profileUrl;
  final String? announcement;
}

class SubscriptionHttpResponse {
  const SubscriptionHttpResponse({required this.body, required this.headers});

  final String body;
  final Map<String, String> headers;
}

class SubscriptionRepository {
  SubscriptionRepository({
    required SubscriptionCache cache,
    SubscriptionParser parser = const SubscriptionParser(),
    HttpClient? client,
    Future<SubscriptionHttpResponse> Function(Uri endpoint)? directFetcher,
    Future<SubscriptionHttpResponse> Function(Uri endpoint)?
    currentRouteFetcher,
  }) : _cache = cache,
       _parser = parser,
       _client = client ?? HttpClient(),
       _directFetcher = directFetcher,
       _currentRouteFetcher = currentRouteFetcher;

  final SubscriptionCache _cache;
  final SubscriptionParser _parser;
  final HttpClient _client;
  final Future<SubscriptionHttpResponse> Function(Uri endpoint)? _directFetcher;
  final Future<SubscriptionHttpResponse> Function(Uri endpoint)?
  _currentRouteFetcher;

  Future<List<VpnNode>> cachedNodes(String subscriptionId) =>
      _cache.readNodes(subscriptionId);

  Future<List<VpnNode>> importText(
    String text, {
    required String subscriptionId,
  }) async {
    final candidate = _parser.parse(text, subscriptionId: subscriptionId);
    _logImportDiagnostics(candidate);
    final merged = await _mergePersistentHistory(subscriptionId, candidate);
    await _cache.replaceNodes(subscriptionId, merged);
    return merged;
  }

  Future<SubscriptionRefreshResult> refreshDirect(
    Uri endpoint, {
    required String subscriptionId,
  }) => _refresh(
    endpoint,
    subscriptionId: subscriptionId,
    fetcher: _directFetcher ?? _fetchWithClient,
  );

  /// Fetches through the process' current route. When Connecso is active,
  /// Android routes this request through its VPN; with no tunnel it is the
  /// normal system route. This is deliberately separate from [refreshDirect],
  /// which can bypass the active VPN on Android.
  Future<SubscriptionRefreshResult> refreshViaCurrentRoute(
    Uri endpoint, {
    required String subscriptionId,
  }) => _refresh(
    endpoint,
    subscriptionId: subscriptionId,
    fetcher: _currentRouteFetcher ?? _fetchWithClient,
  );

  Future<SubscriptionRefreshResult> _refresh(
    Uri endpoint, {
    required String subscriptionId,
    required Future<SubscriptionHttpResponse> Function(Uri) fetcher,
  }) async {
    if (endpoint.scheme != 'https' || endpoint.host.isEmpty) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'An HTTPS subscription URL is required.',
      );
    }
    final fetched = await fetcher(endpoint);
    final body = fetched.body;
    final headers = fetched.headers;
    final candidate = _parser.parse(body, subscriptionId: subscriptionId);
    _logImportDiagnostics(candidate);
    // No cache write happens until fetch, parsing, and validation have all passed.
    final merged = await _mergePersistentHistory(subscriptionId, candidate);
    await _cache.replaceNodes(subscriptionId, merged);
    final explicitAccount = parseSubscriptionAccountEmail(
      headers,
      body,
      endpoint: endpoint,
    );
    final accountEmail =
        explicitAccount ??
        parseSubscriptionAccountFromPreamble(body) ??
        parseSubscriptionAccountFromNodeNames(merged.map((node) => node.name));
    return SubscriptionRefreshResult(
      nodes: merged,
      quota: const UsageService().parseSubscriptionMetadata(headers, body),
      profileTitle: parseSubscriptionProfileTitle(headers, body),
      accountEmail: accountEmail,
      supportUrl: parseSubscriptionSupportUrl(headers, body),
      profileUrl: parseSubscriptionProfileUrl(headers, body),
      announcement: parseSubscriptionAnnouncement(headers, body),
    );
  }

  Future<SubscriptionHttpResponse> _fetchWithClient(Uri endpoint) async {
    final request = await _client
        .getUrl(endpoint)
        .timeout(const Duration(seconds: 12));
    request.followRedirects = true;
    request.maxRedirects = 5;
    final response = await request.close().timeout(const Duration(seconds: 20));
    var redirectTarget = endpoint;
    for (final redirect in response.redirects) {
      redirectTarget = redirectTarget.resolveUri(redirect.location);
      if (redirectTarget.scheme != 'https') {
        await response.drain<void>();
        throw const HttpException(
          'Subscription redirects must remain on HTTPS.',
        );
      }
    }
    if (redirectTarget.scheme != 'https') {
      await response.drain<void>();
      throw const HttpException('Subscription redirects must remain on HTTPS.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw HttpException(
        'Subscription server returned ${response.statusCode}.',
      );
    }
    if (response.contentLength > 5 * 1024 * 1024) {
      await response.drain<void>();
      throw const HttpException(
        'Subscription response exceeds the 5 MiB limit.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      if (bytes.length + chunk.length > 5 * 1024 * 1024) {
        throw const HttpException(
          'Subscription response exceeds the 5 MiB limit.',
        );
      }
      bytes.addAll(chunk);
    }
    final headers = <String, String>{};
    response.headers.forEach(
      (name, values) => headers[name] = values.join(';'),
    );
    return SubscriptionHttpResponse(
      body: utf8.decode(bytes, allowMalformed: false),
      headers: headers,
    );
  }

  void _logImportDiagnostics(List<VpnNode> nodes) {
    final warnings = nodes.expand((node) => node.importWarnings).toSet();
    developer.log(
      'event=subscription.metadata_import nodes=${nodes.length} warnings=${warnings.length}',
      name: 'CONNECSO/METADATA',
    );
    for (final warning in warnings) {
      developer.log(warning, name: 'CONNECSO/METADATA');
    }
  }

  void close() => _client.close(force: true);

  Future<List<VpnNode>> _mergePersistentHistory(
    String subscriptionId,
    List<VpnNode> candidate,
  ) async {
    final previous = await _cache.readNodes(subscriptionId);
    if (previous.isEmpty) return candidate;
    final byId = {for (final node in previous) node.id: node};
    final byEndpoint = {
      for (final node in previous)
        _historyKey(node): node,
    };
    return candidate
        .map((node) {
          final old =
              byId[node.id] ??
              byEndpoint[_historyKey(node)];
          if (old == null) return node;
          return VpnNode.fromJson({
            ...node.toJson(),
            'successCount': old.successCount,
            'failureCount': old.failureCount,
            'stabilityScore': old.stabilityScore,
            'lastSuccess': old.lastSuccess?.toIso8601String(),
            'lastFailure': old.lastFailure?.toIso8601String(),
            'lastProbe': old.lastProbe?.toIso8601String(),
            'latencyMs': old.authoritativeLatency?.inMilliseconds,
            'connectionEstablishmentMs':
                old.connectionEstablishmentTime?.inMilliseconds,
            'health': NodeHealth.unknown.name,
          });
        })
        .toList(growable: false);
  }

  // Host/port alone is not an endpoint identity: one subscription may expose
  // the same address through WS, XHTTP, Reality, or different paths/UUIDs.
  // Reusing probe history across those variants makes AutoSelector prefer a
  // node using measurements from a different transport.
  String _historyKey(VpnNode node) => jsonEncode({
    'protocol': node.protocol.name,
    'host': node.host,
    'port': node.port,
    'transport': node.transport,
    'sni': node.sni,
    'fingerprint': node.fingerprint,
    'uuid': node.credentials['uuid'],
    'path': node.credentials['path'],
    'mode': node.credentials['mode'],
    'tlsSecurity': node.credentials['tlsSecurity'],
  });
}
