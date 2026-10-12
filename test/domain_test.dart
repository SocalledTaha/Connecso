import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:connecso_client/data/parsers/subscription_parser.dart';
import 'package:connecso_client/domain/models/connection_state.dart';
import 'package:connecso_client/domain/models/connection_method.dart';
import 'package:connecso_client/domain/models/vpn_node.dart';
import 'package:connecso_client/domain/services/connection_state_machine.dart';
import 'package:connecso_client/domain/services/core_node_probe.dart';
import 'package:connecso_client/domain/services/core_manager.dart';
import 'package:connecso_client/domain/services/location_resolver.dart';
import 'package:connecso_client/domain/services/smart_selector.dart';
import 'package:connecso_client/domain/services/split_tunnel_policy.dart';
import 'package:connecso_client/domain/services/structured_logger.dart';
import 'package:connecso_client/domain/services/usage_service.dart';
import 'package:connecso_client/domain/services/xray_config_builder.dart';

VpnNode node({
  String id = 'one',
  int successes = 0,
  int failures = 0,
  Duration? latency,
  bool enabled = true,
  NodeHealth health = NodeHealth.unknown,
}) => VpnNode(
  id: id,
  subscriptionId: 'test',
  name: 'Test $id',
  protocol: ProxyProtocol.vless,
  host: 'vpn.example.com',
  port: 443,
  credentials: const {'uuid': '00000000-0000-0000-0000-000000000000'},
  successCount: successes,
  failureCount: failures,
  latency: latency,
  enabled: enabled,
  health: health,
);

void main() {
  group('SubscriptionParser', () {
    const parser = SubscriptionParser();

    test('parses VLESS URI and keeps protocol fields normalized', () {
      final parsed = parser.parse(
        'vless://00000000-0000-0000-0000-000000000000@edge.example:443'
        '?type=ws&security=tls&sni=front.example&path=%2Fvpn#Edge',
        subscriptionId: 'primary',
      );
      expect(parsed, hasLength(1));
      expect(parsed.single.protocol, ProxyProtocol.vless);
      expect(parsed.single.host, 'edge.example');
      expect(parsed.single.transport, 'ws');
      expect(parsed.single.sni, 'front.example');
      expect(parsed.single.credentials['path'], '/vpn');
    });

    test('imports VMess subscription URI', () {
      const vmess =
          'vmess://eyJ2IjoiMiIsInBzIjoiVVMiLCJhZGQiOiJ2cG4uZXhhbXBsZSIsInBvcnQiOiI0NDMiLCJpZCI6IjAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMCIsIm5ldCI6InRjcCIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIn0=';
      final parsed = parser.parse(vmess, subscriptionId: 'primary');
      expect(parsed.single.protocol, ProxyProtocol.vmess);
      expect(parsed.single.name, 'US');
    });

    test('imports Hysteria2 URI and exposes it to method selection', () {
      final parsed = parser.parse(
        'hysteria2://token@example.com:443?sni=example.com&alpn=h3#DE',
        subscriptionId: 'primary',
      );
      expect(parsed, hasLength(1));
      expect(parsed.single.protocol, ProxyProtocol.hysteria);
      expect(parsed.single.transport, 'hysteria');
      expect(parsed.single.credentials['version'], '2');
      expect(
        ConnectionMethod.available(parsed),
        contains(ConnectionMethod.hysteria2),
      );
    });

    test(
      'preserves TLS ALPN fingerprint and ECH in generated Xray outbound',
      () {
        final parsed = parser.parse(
          'vless://00000000-0000-0000-0000-000000000000@edge.example:443'
          '?type=ws&security=tls&sni=front.example&fp=chrome'
          '&alpn=http%2F1.1&ech=cloudflare-ech.com%2Budp%3A%2F%2F1.1.1.1'
          '&path=%2Fvpn&host=front.example#NL',
          subscriptionId: 'metadata',
        );
        final outbound =
            (const XrayConfigBuilder().build(parsed.single)['outbounds']
                        as List)
                    .first
                as Map;
        final stream = outbound['streamSettings'] as Map;
        final tls = stream['tlsSettings'] as Map;
        expect(tls['serverName'], 'front.example');
        expect(tls['fingerprint'], 'chrome');
        expect(tls['alpn'], contains('http/1.1'));
        expect(tls['echConfigList'], 'cloudflare-ech.com+udp://1.1.1.1');
        expect(tls['echForceQuery'], 'full');
        expect((stream['wsSettings'] as Map)['path'], '/vpn');
      },
    );

    test('preserves ECH force-query metadata for the fallback builder', () {
      final parsed = parser
          .parse(
            'vless://00000000-0000-0000-0000-000000000000@edge.example:443'
            '?type=ws&security=tls&sni=front.example&ech=cloudflare-ech.com%2Budp%3A%2F%2F1.1.1.1'
            '&echForceQuery=true#ECH',
            subscriptionId: 'metadata-ech',
          )
          .single;
      final tls =
          (((const XrayConfigBuilder().build(parsed)['outbounds'] as List).first
                      as Map)['streamSettings']
                  as Map)['tlsSettings']
              as Map;
      expect(tls['echConfigList'], 'cloudflare-ech.com+udp://1.1.1.1');
      // URI metadata is preserved verbatim; Xray profiles may use a string
      // mode such as "full" rather than a boolean.
      expect(tls['echForceQuery'], 'true');
    });

    test('normalizes Android clipboard markers around a VLESS URI', () {
      final copied =
          '\uFEFF\u200B  "vless://00000000-0000-0000-0000-000000000000@edge.example:443#Edge"\u200D\n';
      final parsed = parser.parse(copied, subscriptionId: 'clipboard');
      expect(parsed, hasLength(1));
      expect(parsed.single.host, 'edge.example');
      expect(normalizeSubscriptionInput(copied), startsWith('vless://'));
    });

    test(
      'normalizes multiline clipboard proxy lists without changing entries',
      () {
        final copied =
            '\u200Fvless://00000000-0000-0000-0000-000000000000@one.example:443\r\n'
            '\u200E\r\n'
            'vless://00000000-0000-0000-0000-000000000001@two.example:443';
        final parsed = parser.parse(copied, subscriptionId: 'clipboard');
        expect(parsed, hasLength(2));
        expect(
          parsed.map((item) => item.host),
          containsAll(['one.example', 'two.example']),
        );
      },
    );

    test('rejects empty and unsupported input clearly', () {
      expect(
        () => parser.parse(' ', subscriptionId: 'primary'),
        throwsA(isA<SubscriptionFormatException>()),
      );
      expect(
        () => parser.parse('not-a-node', subscriptionId: 'primary'),
        throwsA(isA<SubscriptionFormatException>()),
      );
    });
  });

  group('ConnectionStateMachine', () {
    test('allows a verified connection lifecycle', () {
      final machine = ConnectionStateMachine(ConnectionPhase.disconnected);
      machine.transitionTo(ConnectionPhase.preparing);
      machine.transitionTo(ConnectionPhase.connecting);
      machine.transitionTo(ConnectionPhase.verifying);
      machine.transitionTo(ConnectionPhase.connected);
      expect(machine.phase, ConnectionPhase.connected);
    });

    test('rejects skipping verification', () {
      final machine = ConnectionStateMachine(ConnectionPhase.disconnected);
      machine.transitionTo(ConnectionPhase.preparing);
      expect(
        () => machine.transitionTo(ConnectionPhase.connected),
        throwsA(isA<InvalidConnectionTransition>()),
      );
    });
  });

  group('SmartSelector', () {
    const selector = SmartSelector();

    test('prefers reliable low-latency node and skips unhealthy nodes', () {
      final selected = selector.select([
        node(
          id: 'fast',
          successes: 18,
          failures: 2,
          latency: const Duration(milliseconds: 70),
          health: NodeHealth.healthy,
        ),
        node(
          id: 'unhealthy',
          successes: 100,
          latency: const Duration(milliseconds: 1),
          health: NodeHealth.unhealthy,
        ),
      ]);
      expect(selected?.id, 'fast');
    });

    test('applies switching hysteresis to a similar challenger', () {
      final current = node(
        id: 'current',
        successes: 10,
        latency: const Duration(milliseconds: 100),
        health: NodeHealth.healthy,
      );
      final challenger = node(
        id: 'challenger',
        successes: 10,
        latency: const Duration(milliseconds: 98),
        health: NodeHealth.healthy,
      );
      expect(
        selector.select([challenger, current], current: current)?.id,
        'current',
      );
    });

    test('never keeps an unhealthy current node', () {
      final current = node(
        id: 'current',
        successes: 100,
        latency: const Duration(milliseconds: 1),
        health: NodeHealth.unhealthy,
      );
      final healthy = node(
        id: 'healthy',
        successes: 1,
        latency: const Duration(milliseconds: 900),
        health: NodeHealth.healthy,
      );
      expect(
        selector.select([current, healthy], current: current)?.id,
        'healthy',
      );
    });

    test('does not use connection establishment time in initial ranking', () {
      final quick = VpnNode.fromJson({
        ...node(
          id: 'quick',
          successes: 8,
          latency: const Duration(milliseconds: 80),
          health: NodeHealth.healthy,
        ).toJson(),
        'connectionEstablishmentMs': 1000,
      });
      final slow = VpnNode.fromJson({
        ...node(
          id: 'slow',
          successes: 8,
          latency: const Duration(milliseconds: 80),
          health: NodeHealth.healthy,
        ).toJson(),
        'connectionEstablishmentMs': 12000,
      });
      expect(selector.select([slow, quick])?.id, 'slow');
    });

    test('does not retain a current node absent from eligible candidates', () {
      final current = node(
        id: 'current',
        successes: 100,
        latency: const Duration(milliseconds: 1),
        health: NodeHealth.healthy,
      );
      final healthy = node(
        id: 'healthy',
        successes: 1,
        latency: const Duration(milliseconds: 900),
        health: NodeHealth.healthy,
      );
      expect(selector.select([healthy], current: current)?.id, 'healthy');
    });
  });

  test('parses quota metadata without inventing missing counters', () {
    const service = UsageService();
    final quota = service.parseHeaders({
      'Subscription-Userinfo':
          'upload=1024; download=2048; total=8192; expire=1893456000',
    });
    expect(quota.usedBytes, 3072);
    expect(quota.remainingBytes, 5120);
    expect(quota.expiresAt, isNotNull);
    expect(quota.neverExpires, isFalse);
    final bodyQuota = service.parseSubscriptionMetadata(
      const {},
      '#subscription-userinfo: upload=12; download=34; total=100; expire=1893456000\nvless://node',
    );
    expect(bodyQuota.usedBytes, 46);
    expect(bodyQuota.remainingBytes, 54);
    expect(bodyQuota.expiresAt, isNotNull);
    final base64Body = base64Encode(
      utf8.encode(
        '#subscription-userinfo: upload=12; download=34; total=100; expire=1893456000\nvless://node',
      ),
    );
    final encodedQuota = service.parseSubscriptionMetadata(
      const {},
      base64Body,
    );
    expect(encodedQuota.usedBytes, 46);
    expect(encodedQuota.remainingBytes, 54);
    expect(
      encodedQuota.expiresAt,
      DateTime.fromMillisecondsSinceEpoch(1893456000 * 1000, isUtc: true),
    );
    expect(service.parseHeaders(const {}).usedBytes, isNull);
    final noExpiry = service.parseHeaders({
      'Subscription-Userinfo': 'upload=11; download=22; total=100; expire=0',
    });
    expect(noExpiry.expiresAt, isNull);
    expect(noExpiry.neverExpires, isTrue);
    final unlimited = service.parseHeaders({
      'Subscription-Userinfo': 'upload=11; download=22; total=0; expire=0',
    });
    expect(unlimited.usedBytes, 33);
    expect(unlimited.unlimited, isTrue);
    expect(unlimited.remainingBytes, 0);
    final oversized = service.parseHeaders({
      'Subscription-Userinfo':
          'upload=9223372036854775807; download=9223372036854775807; total=9223372036854775807; expire=9223372036854775807',
    });
    expect(oversized.usedBytes, isNull);
    expect(oversized.expiresAt, isNull);
  });

  test('quota snapshot round-trips through secure storage JSON', () {
    final quota = QuotaSnapshot(
      uploadBytes: 120,
      downloadBytes: 880,
      totalBytes: 2_000,
      expiresAt: DateTime.utc(2030, 1, 1),
    );
    final restored = QuotaSnapshot.decode(jsonEncode(quota.toJson()));

    expect(restored?.usedBytes, 1_000);
    expect(restored?.remainingBytes, 1_000);
    expect(restored?.expiresAt, DateTime.utc(2030, 1, 1));
    final noExpiry = QuotaSnapshot.decode(
      jsonEncode(const QuotaSnapshot(neverExpires: true).toJson()),
    );
    expect(noExpiry?.neverExpires, isTrue);
    expect(QuotaSnapshot.decode('{bad json'), isNull);
  });

  test('structured logger drops credential and URL fields', () {
    String? capturedMessage;
    String? capturedName;
    int? capturedLevel;
    final logger = StructuredLogger(
      sink:
          ({
            required String name,
            required String message,
            required int level,
          }) {
            capturedName = name;
            capturedMessage = message;
            capturedLevel = level;
          },
    );

    logger.record(
      category: LogCategory.subscription,
      severity: LogSeverity.warning,
      event: 'subscription.refresh_failed',
      fields: {
        'failureType': 'HttpException',
        'durationMs': 1200,
        'subscriptionUrl': 'https://example.invalid/private-token',
        'password': 'secret',
      },
    );

    expect(capturedName, 'connecso.subscription');
    expect(capturedLevel, LogSeverity.warning.developerLevel);
    expect(capturedMessage, contains('HttpException'));
    expect(capturedMessage, contains('1200'));
    expect(capturedMessage, isNot(contains('private-token')));
    expect(capturedMessage, isNot(contains('secret')));
  });

  test('resolves known VPN exit names without device location', () {
    final destination = const LocationResolver().resolve(
      node(id: 'fra').copyWithForTest(name: 'Frankfurt DE 01'),
    );
    expect(destination?.city, 'Frankfurt');
  });

  test('does not infer a city from country-only node data', () {
    final unresolved = const LocationResolver().resolve(
      node(
        id: 'de',
      ).copyWithForTest(name: 'Edge DE', country: 'Germany', countryCode: 'DE'),
    );
    expect(unresolved?.country, 'Germany');
    expect(unresolved?.city, isEmpty);
    expect(unresolved?.latitude, isNull);
    expect(unresolved?.longitude, isNull);
  });

  test(
    'resolves country from the connection label when location is absent',
    () {
      final destination = const LocationResolver().resolve(
        node(id: 'de-name').copyWithForTest(
          name: 'Germany Premium',
          country: null,
          countryCode: null,
        ),
      );
      expect(destination?.country, 'Germany');
      expect(destination?.countryCode, 'DE');
      expect(destination?.city, isEmpty);
      expect(destination?.latitude, closeTo(50.9617, 0.0001));
      expect(destination?.longitude, closeTo(9.6783, 0.0001));
    },
  );

  test('does not match a city embedded in an ambiguous larger word', () {
    final unresolved = const LocationResolver().resolve(
      node(id: 'ambiguous').copyWithForTest(name: 'Frankfurtly DE'),
    );
    expect(unresolved?.country, 'Germany');
    expect(unresolved?.city, isEmpty);
  });

  test(
    'core node probe fails closed when no runtime supports the node',
    () async {
      final probe = CoreNodeProbe(CoreManager(_UnsupportedTestCore()));

      final result = await probe.probe(node());

      expect(result.nodeId, 'one');
      expect(result.reachable, isFalse);
      expect(result.latency, isNull);
      expect(result.failureCategory, 'core_unavailable');
    },
  );

  test('split-tunnel policy validates installed package IDs', () {
    const policy = SplitTunnelPolicy(
      mode: SplitTunnelMode.includeSelected,
      packageNames: {'com.example.app'},
    );
    expect(
      () => policy.validateInstalledPackages({'com.example.app'}),
      returnsNormally,
    );
    expect(
      () => policy.validateInstalledPackages(const {}),
      throwsArgumentError,
    );
  });

  test('split-tunnel policy round-trips mode and selected packages', () {
    const policy = SplitTunnelPolicy(
      mode: SplitTunnelMode.includeSelected,
      packageNames: {'com.example.mail', 'com.example.browser'},
    );
    final restored = SplitTunnelPolicy.fromJson(policy.toJson());
    expect(restored.mode, SplitTunnelMode.includeSelected);
    expect(restored.packageNames, policy.packageNames);
  });

  test('split-tunnel list export is versioned and rejects other data', () {
    const policy = SplitTunnelPolicy(
      mode: SplitTunnelMode.includeSelected,
      packageNames: {'com.example.mail', 'com.example.browser'},
    );

    final restored = SplitTunnelPolicy.importText(policy.exportText());

    expect(restored.mode, SplitTunnelMode.includeSelected);
    expect(restored.packageNames, policy.packageNames);
    expect(
      () => SplitTunnelPolicy.importText('{"version":1,"policy":{}}'),
      throwsFormatException,
    );
  });
}

extension on VpnNode {
  VpnNode copyWithForTest({
    String? name,
    String? country,
    String? countryCode,
  }) => VpnNode(
    id: id,
    subscriptionId: subscriptionId,
    name: name ?? this.name,
    protocol: protocol,
    host: host,
    port: port,
    credentials: credentials,
    country: country ?? this.country,
    countryCode: countryCode ?? this.countryCode,
    city: city,
    latitude: latitude,
    longitude: longitude,
  );
}

class _UnsupportedTestCore implements ProxyCore {
  @override
  ProxyCoreKind get kind => ProxyCoreKind.xray;
  @override
  Set<String> get capabilities => const {};
  @override
  String get version => 'test';
  @override
  Future<void> initialize() async {}
  @override
  Future<void> start(
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  }) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> restart(
    VpnNode node, {
    required SplitTunnelPolicy splitTunnelPolicy,
  }) async {}
  @override
  Future<void> reload(VpnNode node) async {}
  @override
  Future<bool> testConnection(VpnNode node) async => false;
  @override
  Future<CoreStats> getStats() async =>
      const CoreStats(uploadBytes: 0, downloadBytes: 0);
  @override
  Future<void> shutdown() async {}
}
