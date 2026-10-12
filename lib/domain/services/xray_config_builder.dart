import 'dart:convert';

import '../models/vpn_node.dart';

/// Produces the Xray configuration for one normalized subscription node.
/// Android HEV feeds the VpnService TUN packets to Xray's local SOCKS inbound.
class XrayConfigBuilder {
  const XrayConfigBuilder();

  static const socksInboundTag = 'connecso-socks';
  static const socksPort = 10808;
  static const proxyTag = 'connecso-proxy';
  static const dnsTag = 'connecso-dns';
  static const blockTag = 'connecso-block';
  static const metricsPort = 49227;

  Map<String, Object?> build(VpnNode node) {
    final outbound = _outbound(node);
    return {
      'log': {'loglevel': 'warning'},
      'dns': {
        'servers': ['1.1.1.1', '8.8.8.8'],
      },
      'stats': <String, Object?>{},
      'policy': {
        'system': {'statsInboundUplink': true, 'statsInboundDownlink': true},
      },
      'metrics': {'listen': '127.0.0.1:$metricsPort'},
      'inbounds': [
        {
          'tag': socksInboundTag,
          'listen': '127.0.0.1',
          'port': socksPort,
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true, 'userLevel': 0},
          'sniffing': {
            'enabled': true,
            'routeOnly': true,
            'destOverride': ['http', 'tls', 'quic'],
          },
        },
      ],
      'outbounds': [
        outbound,
        {'tag': dnsTag, 'protocol': 'dns', 'settings': <String, Object?>{}},
        {
          'tag': blockTag,
          'protocol': 'blackhole',
          'settings': <String, Object?>{},
        },
      ],
      'routing': {
        'domainStrategy': 'AsIs',
        'rules': [
          {'type': 'field', 'port': '53', 'outboundTag': dnsTag},
          {
            'type': 'field',
            'inboundTag': [socksInboundTag],
            'outboundTag': proxyTag,
          },
        ],
      },
    };
  }

  String encode(VpnNode node) => jsonEncode(build(node));

  Map<String, Object?> _outbound(VpnNode node) {
    final credentials = node.credentials;
    final protocol = switch (node.protocol) {
      ProxyProtocol.vless => 'vless',
      ProxyProtocol.vmess => 'vmess',
      ProxyProtocol.trojan => 'trojan',
      ProxyProtocol.shadowsocks => 'shadowsocks',
      ProxyProtocol.hysteria => 'hysteria',
      ProxyProtocol.unknown => throw const FormatException(
        'Unsupported proxy protocol.',
      ),
    };

    final settings = switch (node.protocol) {
      ProxyProtocol.vless => {
        'vnext': [
          {
            'address': node.host,
            'port': node.port,
            'users': [
              {
                'id': _required(credentials, 'uuid'),
                'encryption': credentials['encryption'] ?? 'none',
                if (_nonEmpty(credentials['flow'])) 'flow': credentials['flow'],
              },
            ],
          },
        ],
      },
      ProxyProtocol.vmess => {
        'vnext': [
          {
            'address': node.host,
            'port': node.port,
            'users': [
              {
                'id': _required(credentials, 'uuid'),
                'alterId': int.tryParse(credentials['alterId'] ?? '0') ?? 0,
                'security': credentials['security'] ?? 'auto',
                'level': 0,
              },
            ],
          },
        ],
      },
      ProxyProtocol.trojan => {
        'servers': [
          {
            'address': node.host,
            'port': node.port,
            'password': _required(credentials, 'password'),
          },
        ],
      },
      ProxyProtocol.shadowsocks => {
        'servers': [
          {
            'address': node.host,
            'port': node.port,
            'method': _required(credentials, 'method'),
            'password': _required(credentials, 'password'),
          },
        ],
      },
      ProxyProtocol.hysteria => {
        'address': node.host,
        'port': node.port,
        'version': int.tryParse(credentials['version'] ?? '2') ?? 2,
        if (_nonEmpty(credentials['auth'])) 'auth': credentials['auth'],
      },
      ProxyProtocol.unknown => throw const FormatException(
        'Unsupported proxy protocol.',
      ),
    };

    final defaults = <String, Object?>{
      'tag': proxyTag,
      'protocol': protocol,
      'settings': settings,
      // Mux can reduce handshake overhead but is not a throughput feature.
      // Keep it disabled by default for streaming and bulk-transfer traffic.
      'mux': {'enabled': false},
      if (node.protocol != ProxyProtocol.shadowsocks)
        'streamSettings': _streamSettings(node),
    };
    final supplied = node.xrayOutbound;
    // Import diagnostics are deliberately non-fatal.  Providers often attach
    // client-specific URI hints (for example `fm` fragmentation metadata)
    // which are preserved in sourceMetadata/importWarnings but are not valid
    // Xray fields.  Rejecting the whole node here made one such hint prevent
    // every other endpoint in the subscription from being usable.  Only
    // malformed or missing fields required by the selected Xray outbound are
    // fatal below.
    if (supplied.isEmpty) {
      _normalizeTransportAlpn(defaults);
      return defaults; // Cache from an older build.
    }
    // A native settings object is authoritative. Do not add vnext beside a
    // supplied single-server settings object, or collapse nested arrays.
    final result = _fillAbsent(defaults, supplied);
    if (supplied.containsKey('settings'))
      result['settings'] = _clone(supplied['settings']);
    result['tag'] =
        proxyTag; // The local routing contract, not server metadata.
    final nativeProtocol = result['protocol'];
    if (nativeProtocol != protocol) {
      throw const FormatException(
        'Native outbound protocol does not match the selected node.',
      );
    }
    final stream = result['streamSettings'];
    final sockopt = stream is Map ? stream['sockopt'] : null;
    if (result['proxySettings'] != null ||
        result['dialerProxy'] != null ||
        (sockopt is Map && sockopt['dialerProxy'] != null)) {
      throw const FormatException(
        'Chained native outbounds require an explicit dependency graph.',
      );
    }
    _normalizeTransportAlpn(result);
    return result;
  }

  /// WebSocket handshakes in Xray use HTTP/1.1. Passing a provider's generic
  /// browser ALPN list (often h2,http/1.1,h3) lets TLS negotiate a protocol
  /// that the selected transport cannot carry; the core then connects while
  /// browsers see closed streams. Keep the source metadata intact, but emit
  /// only protocols supported by the actual transport in the runtime config.
  void _normalizeTransportAlpn(Map<String, Object?> outbound) {
    final stream = outbound['streamSettings'];
    if (stream is! Map) return;
    final network = stream['network']?.toString().toLowerCase();
    final tls = stream['tlsSettings'];
    if (tls is! Map || tls['alpn'] is! List) return;
    final values = (tls['alpn'] as List)
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (network == 'ws' && values.isNotEmpty) {
      final http11 = values.where((value) => value == 'http/1.1').toList();
      tls['alpn'] = http11.isNotEmpty ? http11 : values;
    } else if (network == 'xhttp' && values.isNotEmpty) {
      tls['alpn'] = values.where((value) => value != 'h3').toList();
    }
  }

  Object? _clone(Object? value) => jsonDecode(jsonEncode(value));

  /// Defaults fill missing keys only. Explicit false/empty/list/null values
  /// from the provider are preserved, including nested transport settings.
  Map<String, Object?> _fillAbsent(Map defaults, Map supplied) {
    final result = Map<String, Object?>.from(_clone(supplied) as Map);
    for (final entry in defaults.entries) {
      final key = entry.key as String;
      if (!result.containsKey(key)) {
        result[key] = _clone(entry.value);
      } else if (result[key] is Map && entry.value is Map) {
        result[key] = _fillAbsent(entry.value as Map, result[key] as Map);
      }
    }
    return result;
  }

  Map<String, Object?> _streamSettings(VpnNode node) {
    final credentials = node.credentials;
    final network = _xrayNetwork(node.transport);
    final tlsSecurity = credentials['tlsSecurity'] ?? 'none';
    final stream = <String, Object?>{'network': network};

    switch (network) {
      case 'ws':
        stream['wsSettings'] = {
          'path': credentials['path'] ?? '/',
          if (_nonEmpty(credentials['hostHeader']))
            'host': credentials['hostHeader'],
          'headers': {
            'User-Agent': credentials['userAgent'] ?? 'chrome',
          },
        };
      case 'grpc':
        stream['grpcSettings'] = {
          'serviceName': credentials['serviceName'] ?? '',
        };
      case 'httpupgrade':
        stream['httpupgradeSettings'] = {
          'path': credentials['path'] ?? '/',
          if (_nonEmpty(credentials['hostHeader']))
            'host': credentials['hostHeader'],
        };
      case 'xhttp':
        stream['xhttpSettings'] = {
          'path': credentials['path'] ?? '/',
          if (_nonEmpty(credentials['hostHeader']))
            'host': credentials['hostHeader'],
          if (_nonEmpty(credentials['mode'])) 'mode': credentials['mode'],
          if (_nonEmpty(credentials['xhttpExtra']))
            'extra': _decodeJsonObject(credentials['xhttpExtra']!),
        };
      case 'hysteria':
        // Current Xray transport schema names the Hysteria transport method
        // explicitly. Keep the normalized network value as well for older
        // cores, but never omit method from a Hysteria2 outbound.
        stream['method'] = 'hysteria';
        stream['hysteriaSettings'] = {
          'version': int.tryParse(credentials['version'] ?? '2') ?? 2,
          if (_nonEmpty(credentials['auth'])) 'auth': credentials['auth'],
        };
        if (_nonEmpty(credentials['hysteriaSettings']))
          stream['hysteriaSettings'] = _decodeJsonObject(
            credentials['hysteriaSettings']!,
          );
        if (_nonEmpty(credentials['hysteriaMask']))
          stream['finalmask'] = _decodeJsonObject(credentials['hysteriaMask']!);
      default:
        break;
    }

    if (tlsSecurity == 'tls') {
      stream['security'] = 'tls';
      stream['tlsSettings'] = {
        'serverName': node.sni ?? node.host,
        if (credentials['allowInsecure'] == 'true') 'allowInsecure': true,
        if (_nonEmpty(credentials['pinSHA256']))
          'pinnedPeerCertSha256': [credentials['pinSHA256']],
        if (_nonEmpty(credentials['echConfigList']))
          'echConfigList': credentials['echConfigList'],
        if (_nonEmpty(credentials['echForceQuery']))
          'echForceQuery': _structuredBooleanOrMode(
            credentials['echForceQuery']!,
          ),
        // Match the common TLS/WS server profile when the subscription does
        // not explicitly provide a uTLS fingerprint.
        'fingerprint': node.fingerprint ?? 'chrome',
        if (_nonEmpty(credentials['alpn']))
          'alpn': credentials['alpn']!
              .split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(),
      };
    } else if (tlsSecurity == 'reality') {
      final publicKey = _required(credentials, 'publicKey');
      stream['security'] = 'reality';
      stream['realitySettings'] = {
        'serverName': node.sni ?? node.host,
        'fingerprint': node.fingerprint ?? 'chrome',
        'publicKey': publicKey,
        'shortId': credentials['shortId'] ?? '',
        if (_nonEmpty(credentials['spiderX']))
          'spiderX': credentials['spiderX'],
        // Keep provider metadata available for Xray versions that accept
        // ALPN alongside REALITY/XHTTP. It is harmless when omitted.
        if (_nonEmpty(credentials['alpn']))
          'alpn': credentials['alpn']!
              .split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(),
      };
    } else if (tlsSecurity != 'none') {
      throw const FormatException('Unsupported TLS security mode.');
    }
    return stream;
  }

  String _xrayNetwork(String transport) => switch (transport.toLowerCase()) {
    'tcp' || 'raw' => 'tcp',
    'ws' || 'websocket' => 'ws',
    'grpc' || 'gun' => 'grpc',
    'httpupgrade' => 'httpupgrade',
    'xhttp' || 'splithttp' => 'xhttp',
    'hysteria' || 'hysteria2' => 'hysteria',
    _ => throw FormatException('Unsupported Xray transport: $transport.'),
  };

  String _required(Map<String, String> values, String key) {
    final value = values[key]?.trim();
    if (value == null || value.isEmpty) {
      throw FormatException('Proxy configuration is missing $key.');
    }
    return value;
  }

  bool _nonEmpty(String? value) => value != null && value.isNotEmpty;

  Object _structuredBooleanOrMode(String value) {
    final normalized = value.toLowerCase();
    if (value == '1' || normalized == 'true' || normalized == 'yes') {
      return true;
    }
    if (value == '0' || normalized == 'false' || normalized == 'no') {
      return false;
    }
    // Some providers use a named Xray mode, for example "full".
    return value;
  }

  Object? _decodeJsonObject(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return decoded;
    } catch (_) {
      // Never print a configuration value: it can contain credentials.
    }
    throw const FormatException('Invalid structured Xray connection metadata.');
  }
}
