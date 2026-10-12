import 'dart:convert';

import 'package:connecso_client/data/parsers/subscription_parser.dart';
import 'package:connecso_client/domain/models/vpn_node.dart';
import 'package:connecso_client/domain/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const builder = XrayConfigBuilder();

  test('builds VLESS Reality and the local SOCKS inbound used by HEV', () {
    final config = builder.build(
      _node(
        protocol: ProxyProtocol.vless,
        transport: 'ws',
        credentials: const {
          'uuid': 'test-uuid',
          'flow': 'xtls-rprx-vision',
          'tlsSecurity': 'reality',
          'publicKey': 'test-public-key',
          'shortId': 'abcd',
          'path': '/connect',
          'hostHeader': 'cdn.example.com',
        },
        sni: 'front.example.com',
        fingerprint: 'chrome',
      ),
    );
    final outbounds = config['outbounds']! as List;
    final outbound = outbounds.first as Map;
    final routing = config['routing']! as Map;
    final stream = outbound['streamSettings']! as Map;
    final reality = stream['realitySettings']! as Map;

    expect(outbound['protocol'], 'vless');
    expect(outbound['tag'], XrayConfigBuilder.proxyTag);
    expect(outbound['mux'], {'enabled': false});
    expect((routing['rules'] as List), [
      {'type': 'field', 'port': '53', 'outboundTag': XrayConfigBuilder.dnsTag},
      {
        'type': 'field',
        'inboundTag': [XrayConfigBuilder.socksInboundTag],
        'outboundTag': XrayConfigBuilder.proxyTag,
      },
    ]);
    expect(config['dns'], {
      'servers': ['1.1.1.1', '8.8.8.8'],
    });
    expect(outbounds[1], {
      'tag': XrayConfigBuilder.dnsTag,
      'protocol': 'dns',
      'settings': <String, Object?>{},
    });
    expect(outbounds.last, {
      'tag': XrayConfigBuilder.blockTag,
      'protocol': 'blackhole',
      'settings': <String, Object?>{},
    });
    expect(
      (((outbound['settings'] as Map)['vnext'] as List).single
          as Map)['address'],
      'edge.example.com',
    );
    expect(stream['network'], 'ws');
    expect((stream['wsSettings'] as Map)['path'], '/connect');
    expect(reality['serverName'], 'front.example.com');
    expect(reality['publicKey'], 'test-public-key');
    expect(
      (routing['rules'] as List).last['outboundTag'],
      XrayConfigBuilder.proxyTag,
    );
    final inbound = (config['inbounds']! as List).single as Map;
    expect(inbound['protocol'], 'socks');
    expect(inbound['listen'], '127.0.0.1');
    expect(inbound['port'], XrayConfigBuilder.socksPort);
    expect(inbound['tag'], XrayConfigBuilder.socksInboundTag);
    expect((inbound['settings'] as Map)['udp'], isTrue);
    expect(config['metrics'], {
      'listen': '127.0.0.1:${XrayConfigBuilder.metricsPort}',
    });
    expect(
      ((config['policy'] as Map)['system'] as Map)['statsInboundUplink'],
      isTrue,
    );
  });

  test('allows QUIC while DNS and IPv6 use the controlled routing rules', () {
    final config = builder.build(
      _node(
        credentials: const {
          'uuid': 'test-uuid',
          'flow': 'xtls-rprx-vision-udp443',
        },
      ),
    );
    final outbounds = config['outbounds']! as List;
    final outbound = outbounds.first as Map;
    final rules = (config['routing']! as Map)['rules']! as List;
    expect(outbounds, hasLength(3));
    expect(outbound['mux'], {'enabled': false});
    expect(
      rules.any(
        (rule) =>
            rule is Map &&
            rule['network'] == 'udp' &&
            rule['port'] == '443' &&
            rule['outboundTag'] == XrayConfigBuilder.blockTag,
      ),
      isFalse,
    );
    expect(rules.first, {
      'type': 'field',
      'port': '53',
      'outboundTag': XrayConfigBuilder.dnsTag,
    });
    expect(rules[1], {
      'type': 'field',
      'inboundTag': [XrayConfigBuilder.socksInboundTag],
      'outboundTag': XrayConfigBuilder.proxyTag,
    });
  });

  test('keeps VMess cipher separate from TLS transport security', () {
    final config = builder.build(
      _node(
        protocol: ProxyProtocol.vmess,
        credentials: const {
          'uuid': 'test-uuid',
          'alterId': '4',
          'security': 'chacha20-poly1305',
          'tlsSecurity': 'tls',
        },
        sni: 'vmess.example.com',
      ),
    );
    final outbound = (config['outbounds']! as List).first as Map;
    final user =
        ((((outbound['settings'] as Map)['vnext'] as List).single
                        as Map)['users']
                    as List)
                .single
            as Map;
    final stream = outbound['streamSettings'] as Map;

    expect(user['security'], 'chacha20-poly1305');
    expect(user['alterId'], 4);
    expect(stream['security'], 'tls');
    expect((stream['tlsSettings'] as Map)['serverName'], 'vmess.example.com');
  });

  test(
    'builds a Hysteria2 outbound with the explicit Xray transport method',
    () {
      final config = builder.build(
        _node(
          protocol: ProxyProtocol.hysteria,
          transport: 'hysteria',
          credentials: const {'version': '2', 'auth': 'test-password'},
        ),
      );
      final outbound = (config['outbounds']! as List).first as Map;
      final stream = outbound['streamSettings'] as Map;
      expect(outbound['protocol'], 'hysteria');
      expect((outbound['settings'] as Map)['version'], 2);
      expect(stream['network'], 'hysteria');
      expect(stream['method'], 'hysteria');
      expect((stream['hysteriaSettings'] as Map)['version'], 2);
      expect((stream['hysteriaSettings'] as Map)['auth'], 'test-password');
    },
  );

  test('keeps named ECH force-query modes in legacy fallback metadata', () {
    final config = builder.build(
      _node(
        transport: 'ws',
        credentials: const {
          'uuid': 'test-uuid',
          'tlsSecurity': 'tls',
          'echConfigList': 'cloudflare-ech.com+udp://1.1.1.1',
          'echForceQuery': 'full',
        },
      ),
    );
    final stream =
        ((config['outbounds']! as List).first as Map)['streamSettings'] as Map;
    expect((stream['tlsSettings'] as Map)['echForceQuery'], 'full');
  });

  test('uses HTTP/1.1 for WebSocket TLS even when provider lists h2 and h3', () {
    final node = _node(
      transport: 'ws',
      credentials: const {
        'uuid': 'test-uuid',
        'tlsSecurity': 'tls',
        'alpn': 'h2,http/1.1,h3',
      },
    );
    final stream =
        ((builder.build(node)['outbounds']! as List).first as Map)['streamSettings']
            as Map;
    expect((stream['tlsSettings'] as Map)['alpn'], ['http/1.1']);
  });

  test('rejects nodes without required credentials or supported transport', () {
    expect(
      () => builder.build(
        _node(protocol: ProxyProtocol.vless, credentials: const {}),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => builder.build(
        _node(protocol: ProxyProtocol.vless, transport: 'quic'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('VMess parsing preserves cipher and TLS as distinct fields', () {
    final source = base64Encode(
      utf8.encode(
        jsonEncode({
          'add': 'vmess.example.com',
          'port': '443',
          'id': 'test-uuid',
          'aid': '0',
          'scy': 'chacha20-poly1305',
          'tls': 'tls',
          'net': 'tcp',
          'sni': 'front.example.com',
        }),
      ),
    );

    final parsed = const SubscriptionParser()
        .parse('vmess://$source', subscriptionId: 'test')
        .single;

    expect(parsed.credentials['security'], 'chacha20-poly1305');
    expect(parsed.credentials['tlsSecurity'], 'tls');
    expect(parsed.sni, 'front.example.com');
  });

  test('normalizes a proxy JSON input before generating Xray config', () {
    final node = const SubscriptionParser()
        .parse(
          jsonEncode({
            'outbounds': [
              {
                'type': 'vless',
                'tag': 'JSON node',
                'server': 'json.example.com',
                'server_port': 443,
                'uuid': 'json-uuid',
                'tls': {'enabled': true, 'server_name': 'front.example.com'},
              },
            ],
          }),
          subscriptionId: 'json-subscription',
        )
        .single;

    final outbound = (builder.build(node)['outbounds']! as List).first as Map;
    expect(node.protocol, ProxyProtocol.vless);
    expect(node.name, 'JSON node');
    expect(outbound['protocol'], 'vless');
    expect(outbound['mux'], {'enabled': false});
    expect((outbound['streamSettings'] as Map)['security'], 'tls');
  });

  test('migrates the version 1 node-list cache to schema version 2', () {
    final legacyNode = _node(
      protocol: ProxyProtocol.vmess,
      credentials: const {'uuid': 'test-uuid', 'security': 'tls'},
    );
    final restored = decodeNodes(jsonEncode([legacyNode.toJson()])).single;
    final currentCache = encodeNodes([restored]);

    expect(restored.credentials['tlsSecurity'], 'tls');
    expect(restored.credentials['security'], 'auto');
    expect((jsonDecode(currentCache) as Map)['schemaVersion'], 2);
    expect(decodeNodes(currentCache).single.credentials['tlsSecurity'], 'tls');
  });
}

VpnNode _node({
  ProxyProtocol protocol = ProxyProtocol.vless,
  String transport = 'tcp',
  Map<String, String> credentials = const {'uuid': 'test-uuid'},
  String? sni,
  String? fingerprint,
}) => VpnNode(
  id: 'node',
  subscriptionId: 'test',
  name: 'Test node',
  protocol: protocol,
  host: 'edge.example.com',
  port: 443,
  credentials: credentials,
  transport: transport,
  sni: sni,
  fingerprint: fingerprint,
);
