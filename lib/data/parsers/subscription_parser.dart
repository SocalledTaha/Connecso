import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../../domain/models/vpn_node.dart';
import 'xray_subscription_metadata.dart';

class SubscriptionFormatException implements Exception {
  const SubscriptionFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Normalizes text copied from Android clipboards before it is interpreted as
/// either a subscription URL or a proxy list. Samsung's clipboard can preserve
/// BOM, zero-width and bidi marker characters around a copied link, and can
/// also normalize line endings differently from other Android keyboards/apps.
/// These characters are presentation metadata, not part of a proxy URI.
String normalizeSubscriptionInput(String input) {
  var value = input
      .replaceAll(
        RegExp(r'[\uFEFF\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069]'),
        '',
      )
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .trim();
  // A few clipboard providers wrap a single copied URL in quotes. Remove
  // only a matching outer pair so encoded quote characters remain untouched.
  if (value.length >= 2) {
    final first = value.codeUnitAt(0);
    final last = value.codeUnitAt(value.length - 1);
    final quoted =
        (first == 0x22 && last == 0x22) || (first == 0x27 && last == 0x27);
    if (quoted) value = value.substring(1, value.length - 1).trim();
  }
  return value
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

class SubscriptionParser {
  const SubscriptionParser();

  List<VpnNode> parse(String input, {required String subscriptionId}) {
    final text = normalizeSubscriptionInput(input);
    if (text.isEmpty) {
      throw const SubscriptionFormatException('Subscription is empty.');
    }
    final decoded = _decodeList(text).trim();
    if (decoded.startsWith('{') || decoded.startsWith('[')) {
      return _parseProxyJsonConfig(decoded, subscriptionId);
    }
    if (decoded.startsWith('proxies:') || decoded.startsWith('mixed-port:')) {
      return _parseClashConfig(decoded, subscriptionId);
    }
    final lines = decoded.split(RegExp(r'[\r\n]+'));
    final nodes = <VpnNode>[];
    final errors = <String>[];
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      try {
        nodes.add(_parseLine(line, subscriptionId));
      } on FormatException catch (error) {
        errors.add(
          error.message.startsWith('Invalid JSON object in')
              ? error.message
              : 'A proxy entry has invalid syntax.',
        );
      } on SubscriptionFormatException catch (error) {
        errors.add(error.message);
      }
    }
    if (nodes.isEmpty) {
      final detail = errors.isEmpty ? '' : ' ${errors.first}';
      throw SubscriptionFormatException(
        'No supported proxy nodes found.$detail',
      );
    }
    if (errors.isNotEmpty) {
      return nodes
          .map(
            (node) => VpnNode.fromJson({
              ...node.toJson(),
              'importWarnings': [
                ...node.importWarnings,
                '${errors.length} subscription entries rejected: ${errors.toSet().join(' ')}',
              ],
            }),
          )
          .toList();
    }
    return nodes;
  }

  String _decodeList(String input) {
    if (RegExp(
      r'^(?:vless|vmess|trojan|ss|hy2|hysteria2)://',
      caseSensitive: false,
    ).hasMatch(input)) {
      return input;
    }
    final compact = input.replaceAll(RegExp(r'\s+'), '');
    try {
      final normalized = base64.normalize(compact);
      final decoded = utf8.decode(
        base64Decode(normalized),
        allowMalformed: true,
      );
      if (RegExp(
        r'^(?:vless|vmess|trojan|ss|hy2|hysteria2)://|\{|\[|proxies:|mixed-port:',
        caseSensitive: false,
      ).hasMatch(decoded.trimLeft())) {
        return decoded;
      }
    } on FormatException {
      // Plain, unsupported text is rejected by the protocol parser below.
    }
    return input;
  }

  List<VpnNode> _parseProxyJsonConfig(String source, String subscriptionId) {
    final raw = jsonDecode(source);
    // Panels can return an array of complete Xray profiles.
    final profiles = raw is List ? raw : [raw];
    final outbounds = <Object?>[];
    for (final profile in profiles) {
      if (profile is! Map || profile['outbounds'] is! List) {
        throw const SubscriptionFormatException(
          'Proxy JSON has no outbounds list.',
        );
      }
      outbounds.addAll(profile['outbounds'] as List);
    }
    final nodes = <VpnNode>[];
    for (final item in outbounds.whereType<Map>()) {
      final row = _normalizeXrayOutbound(Map<String, dynamic>.from(item));
      try {
        nodes.add(_parseMapNode(row, subscriptionId, nameKey: 'tag'));
      } on SubscriptionFormatException {
        if (!const ['freedom', 'blackhole', 'dns'].contains(item['protocol'])) {
          throw const SubscriptionFormatException(
            'A proxy outbound could not be imported without losing metadata.',
          );
        }
      }
    }
    if (nodes.isEmpty) {
      throw const SubscriptionFormatException(
        'No supported proxy outbounds found.',
      );
    }
    return nodes;
  }

  List<VpnNode> _parseClashConfig(String source, String subscriptionId) {
    final yaml = loadYaml(source);
    if (yaml is! YamlMap || yaml['proxies'] is! YamlList) {
      throw const SubscriptionFormatException(
        'Clash configuration has no proxies list.',
      );
    }
    final nodes = <VpnNode>[];
    var rejected = 0;
    for (final proxy in (yaml['proxies'] as YamlList).whereType<YamlMap>()) {
      final row = <String, dynamic>{
        for (final entry in proxy.entries) entry.key.toString(): entry.value,
      };
      try {
        nodes.add(
          _parseMapNode(row, subscriptionId, nameKey: 'name', clash: true),
        );
      } on SubscriptionFormatException {
        rejected++;
      }
    }
    if (nodes.isEmpty) {
      throw const SubscriptionFormatException(
        'No supported Clash proxy nodes found.',
      );
    }
    return rejected == 0
        ? nodes
        : nodes
              .map(
                (node) => VpnNode.fromJson({
                  ...node.toJson(),
                  'importWarnings': [
                    ...node.importWarnings,
                    '$rejected YAML proxy entries rejected during import.',
                  ],
                }),
              )
              .toList();
  }

  VpnNode _parseMapNode(
    Map<String, dynamic> row,
    String subscriptionId, {
    required String nameKey,
    bool clash = false,
  }) {
    final protocol = switch ((row['type'] ?? '').toString().toLowerCase()) {
      'vless' => ProxyProtocol.vless,
      'vmess' => ProxyProtocol.vmess,
      'trojan' => ProxyProtocol.trojan,
      'shadowsocks' || 'ss' => ProxyProtocol.shadowsocks,
      'hysteria' || 'hysteria2' => ProxyProtocol.hysteria,
      _ => ProxyProtocol.unknown,
    };
    if (protocol == ProxyProtocol.unknown) {
      throw const SubscriptionFormatException('Unsupported proxy type.');
    }
    final host = row['server']?.toString() ?? '';
    final port =
        int.tryParse(
          (clash ? row['port'] : row['server_port'])?.toString() ?? '',
        ) ??
        0;
    if (host.isEmpty || port < 1 || port > 65535) {
      throw const SubscriptionFormatException('Proxy host or port is invalid.');
    }
    final auth =
        (row['uuid'] ??
                row['password'] ??
                row['hysteriaAuth'] ??
                row['auth'] ??
                '')
            .toString();
    if (auth.isEmpty) {
      throw const SubscriptionFormatException(
        'Proxy authentication is missing.',
      );
    }
    final streamSettings = row['streamSettings'] is Map
        ? Map<String, dynamic>.from(row['streamSettings'] as Map)
        : const <String, dynamic>{};
    final tlsSettings = streamSettings['tlsSettings'] is Map
        ? Map<String, dynamic>.from(streamSettings['tlsSettings'] as Map)
        : const <String, dynamic>{};
    final realitySettings = streamSettings['realitySettings'] is Map
        ? Map<String, dynamic>.from(streamSettings['realitySettings'] as Map)
        : const <String, dynamic>{};
    final wsSettings = streamSettings['wsSettings'] is Map
        ? Map<String, dynamic>.from(streamSettings['wsSettings'] as Map)
        : const <String, dynamic>{};
    final xhttpSettings = streamSettings['xhttpSettings'] is Map
        ? Map<String, dynamic>.from(streamSettings['xhttpSettings'] as Map)
        : const <String, dynamic>{};
    final tls = row['tls'] is Map
        ? Map<String, dynamic>.from(row['tls'] as Map)
        : (streamSettings['security'] != null
              ? <String, dynamic>{
                  'enabled': streamSettings['security'] == 'tls',
                  'server_name': tlsSettings['serverName'],
                  'alpn': tlsSettings['alpn'],
                }
              : const <String, dynamic>{});
    final transport = row['transport'] is Map
        ? Map<String, dynamic>.from(row['transport'] as Map)
        : <String, dynamic>{
            'type': streamSettings['network'] ?? row['network'],
            'path': wsSettings['path'] ?? xhttpSettings['path'],
            'headers': wsSettings['headers'] ?? const <String, dynamic>{},
            'host': wsSettings['host'] ?? xhttpSettings['host'],
            'mode': xhttpSettings['mode'],
            'xhttpSettings': xhttpSettings,
          };
    final clashWs = _mapValue(row['ws-opts'] ?? row['ws_opts']);
    final clashXhttp = _mapValue(row['xhttp-opts'] ?? row['xhttp_opts']);
    if (clashWs != null) {
      transport['path'] ??= clashWs['path'];
      if (transport['headers'] is! Map ||
          (transport['headers'] as Map).isEmpty) {
        transport['headers'] = clashWs['headers'];
      }
      transport['host'] ??= clashWs['headers'] is Map
          ? (clashWs['headers'] as Map)['Host'] ??
                (clashWs['headers'] as Map)['host']
          : null;
    }
    if (clashXhttp != null) {
      transport['path'] ??= clashXhttp['path'];
      transport['host'] ??= clashXhttp['host'];
      transport['mode'] ??= clashXhttp['mode'];
    }
    final reality = row['reality'] is Map
        ? Map<String, dynamic>.from(row['reality'] as Map)
        : row['reality-opts'] is Map
        ? Map<String, dynamic>.from(row['reality-opts'] as Map)
        : (realitySettings.isNotEmpty
              ? realitySettings
              : const <String, dynamic>{});
    final tlsReality = tls['reality'] is Map
        ? Map<String, dynamic>.from(tls['reality'] as Map)
        : reality;
    final usesReality = tlsReality.isNotEmpty;
    final transportHeaders = transport['headers'] is Map
        ? Map<String, dynamic>.from(transport['headers'] as Map)
        : const <String, dynamic>{};
    final normalizedTransport = protocol == ProxyProtocol.hysteria
        ? 'hysteria'
        : _normalizeTransport(
            (transport['type'] ??
                    transport['network'] ??
                    (xhttpSettings.isNotEmpty ? 'xhttp' : null) ??
                    (clashWs != null ? 'ws' : null) ??
                    (clashXhttp != null ? 'xhttp' : null) ??
                    row['network'] ??
                    'tcp')
                .toString(),
          );
    // Providers commonly put ALPN on the TLS object, while some Clash
    // profiles put it on the transport object or at the top level. Preserve
    // it while normalizing the node; otherwise manually selected nodes can
    // lose the TLS handshake metadata that the automatic path used.
    final alpn = _stringValue(
      tls['alpn'] ?? tlsReality['alpn'] ?? transport['alpn'] ?? row['alpn'],
    );
    final tlsEnabled =
        protocol == ProxyProtocol.hysteria ||
        (clash
            ? row['tls'] == true ||
                  row['tls']?.toString().toLowerCase() == 'true'
            : tls['enabled'] == true ||
                  streamSettings['security'] == 'tls' ||
                  row['tls'] == true);
    final metadata = XraySubscriptionMetadata.map(row);
    return VpnNode(
      id: _id(subscriptionId, jsonEncode(row)),
      xrayOutbound: metadata.outbound,
      sourceMetadata: metadata.source,
      importWarnings: metadata.warnings,
      subscriptionId: subscriptionId,
      name: (row[nameKey] ?? '$host:$port').toString(),
      protocol: protocol,
      host: host,
      port: port,
      credentials: {
        if (protocol == ProxyProtocol.hysteria) 'auth': auth,
        if (row['uuid'] != null) 'uuid': auth,
        if (row['password'] != null) 'password': auth,
        if (row['hysteriaAuth'] != null) 'auth': auth,
        if (row['type']?.toString().toLowerCase() == 'hysteria2')
          'version': '2'
        else if (row['hysteriaVersion'] != null)
          'version': row['hysteriaVersion'].toString(),
        if (row['hysteriaMask'] != null)
          'hysteriaMask': row['hysteriaMask'].toString(),
        if (row['method'] != null) 'method': row['method'].toString(),
        if (row['cipher'] != null) 'method': row['cipher'].toString(),
        if (row['alterId'] != null || row['alter-id'] != null)
          'alterId': (row['alterId'] ?? row['alter-id']).toString(),
        if (row['encryption'] != null)
          'encryption': row['encryption'].toString(),
        if (row['flow'] != null) 'flow': row['flow'].toString(),
        if (row['xhttpExtra'] != null)
          'xhttpExtra': row['xhttpExtra'].toString(),
        if (tlsReality['public_key'] != null ||
            tlsReality['public-key'] != null ||
            tlsReality['publicKey'] != null)
          'publicKey':
              (tlsReality['public_key'] ??
                      tlsReality['public-key'] ??
                      tlsReality['publicKey'])
                  .toString(),
        if (tlsReality['short_id'] != null ||
            tlsReality['short-id'] != null ||
            tlsReality['shortId'] != null)
          'shortId':
              (tlsReality['short_id'] ??
                      tlsReality['short-id'] ??
                      tlsReality['shortId'])
                  .toString(),
        'tlsSecurity': usesReality
            ? 'reality'
            : tlsEnabled
            ? 'tls'
            : 'none',
        if (transport['path'] != null) 'path': transport['path'].toString(),
        if (transport['mode'] != null) 'mode': transport['mode'].toString(),
        if (transport['xhttpSettings'] is Map)
          ..._stringMap(transport['xhttpSettings'] as Map),
        if (transportHeaders['Host'] != null)
          'hostHeader': transportHeaders['Host'].toString(),
        if (transportHeaders['host'] != null)
          'hostHeader': transportHeaders['host'].toString(),
        if (transport['host'] != null)
          'hostHeader': transport['host'].toString(),
        if (transportHeaders['User-Agent'] != null)
          'userAgent': transportHeaders['User-Agent'].toString(),
        if (transportHeaders['user-agent'] != null)
          'userAgent': transportHeaders['user-agent'].toString(),
        if (alpn != null) 'alpn': alpn,
      },
      transport: normalizedTransport,
      sni:
          (tls['server_name'] ??
                  tls['serverName'] ??
                  row['servername'] ??
                  row['serverName'] ??
                  row['server-name'] ??
                  row['sni'] ??
                  tlsReality['serverName'])
              ?.toString(),
      fingerprint:
          (tls['utls'] is Map ? (tls['utls'] as Map)['fingerprint'] : null) ??
          tlsSettings['fingerprint']?.toString() ??
          realitySettings['fingerprint']?.toString() ??
          row['client-fingerprint']?.toString(),
    );
  }

  VpnNode _parseLine(String line, String subscriptionId) {
    final separator = line.indexOf(':');
    if (separator <= 0) {
      throw const SubscriptionFormatException('Unsupported proxy URI.');
    }
    final scheme = line.substring(0, separator).toLowerCase();
    return switch (scheme) {
      'vless' => _parseUri(line, subscriptionId, ProxyProtocol.vless),
      'trojan' => _parseUri(line, subscriptionId, ProxyProtocol.trojan),
      'ss' => _parseShadowsocks(line, subscriptionId),
      'vmess' => _parseVmess(line, subscriptionId),
      'hy2' || 'hysteria2' => _parseHysteria2(line, subscriptionId),
      _ => throw const SubscriptionFormatException('Unsupported proxy URI.'),
    };
  }

  VpnNode _parseHysteria2(String source, String subscriptionId) {
    final uri = Uri.parse(source);
    final query = uri.queryParameters;
    final port = uri.hasPort ? uri.port : 443;
    if (uri.host.isEmpty || port < 1 || port > 65535) {
      throw const SubscriptionFormatException(
        'Hysteria2 host or port is invalid.',
      );
    }
    final auth = Uri.decodeComponent(uri.userInfo);
    final obfs = query['obfs'];
    if (obfs != null && obfs.isNotEmpty && obfs != 'salamander') {
      throw const SubscriptionFormatException(
        'Unsupported Hysteria2 obfuscation.',
      );
    }
    if (obfs == 'salamander' && (query['obfs-password'] ?? '').isEmpty) {
      throw const SubscriptionFormatException(
        'Hysteria2 obfuscation password is missing.',
      );
    }
    final metadata = XraySubscriptionMetadata.uri(uri, hysteria: true);
    return VpnNode(
      id: _id(subscriptionId, source),
      xrayOutbound: metadata.outbound,
      sourceMetadata: metadata.source,
      importWarnings: metadata.warnings,
      subscriptionId: subscriptionId,
      name: uri.fragment.isEmpty
          ? 'Hysteria2'
          : Uri.decodeComponent(uri.fragment),
      protocol: ProxyProtocol.hysteria,
      host: uri.host,
      port: port,
      transport: 'hysteria',
      sni: query['sni'] ?? uri.host,
      fingerprint: query['fp'],
      credentials: {
        'version': '2',
        'auth': auth,
        'tlsSecurity': 'tls',
        'alpn': query['alpn'] ?? 'h3',
        'hysteriaSettings': jsonEncode({'version': 2, 'auth': auth}),
        if (query['insecure'] != null)
          'allowInsecure': query['insecure'] == '1' ? 'true' : 'false',
        if (query['pinSHA256'] != null) 'pinSHA256': query['pinSHA256']!,
        if (query['ech'] != null) 'echConfigList': query['ech']!,
        if (query['echForceQuery'] != null)
          'echForceQuery': query['echForceQuery']!,
        if (query['ech_force_query'] != null)
          'echForceQuery': query['ech_force_query']!,
        if (obfs == 'salamander')
          'hysteriaMask': jsonEncode({
            'udp': [
              {
                'type': 'salamander',
                'settings': {'password': query['obfs-password']},
              },
            ],
          }),
      },
    );
  }

  VpnNode _parseUri(
    String source,
    String subscriptionId,
    ProxyProtocol protocol,
  ) {
    final uri = Uri.parse(source);
    final host = uri.host.trim();
    final port = uri.port;
    if (host.isEmpty || port < 1 || port > 65535) {
      throw const SubscriptionFormatException('Proxy host or port is invalid.');
    }
    final user = Uri.decodeComponent(uri.userInfo);
    if (user.isEmpty) {
      throw const SubscriptionFormatException(
        'Proxy authentication is missing.',
      );
    }
    final query = uri.queryParameters;
    final transport = _normalizeTransport(
      query['type'] ?? query['network'] ?? 'tcp',
    );
    final credentials = <String, String>{
      if (protocol == ProxyProtocol.vless) 'uuid': user,
      if (protocol == ProxyProtocol.trojan) 'password': user,
      if (query['security'] == 'reality') ...{
        if (query['pbk'] != null) 'publicKey': query['pbk']!,
        if (query['sid'] != null) 'shortId': query['sid']!,
      },
      if (query['path'] != null) 'path': query['path']!,
      if (query['host'] != null) 'hostHeader': query['host']!,
      if (query['alpn'] != null) 'alpn': query['alpn']!,
      if (query['encryption'] != null) 'encryption': query['encryption']!,
      if (query['serviceName'] != null) 'serviceName': query['serviceName']!,
      if (query['mode'] != null) 'mode': query['mode']!,
      if (query['extra'] != null) 'xhttpExtra': query['extra']!,
      if (query['x_padding_bytes'] != null)
        'xPaddingBytes': query['x_padding_bytes']!,
      if (query['flow'] != null) 'flow': query['flow']!,
      if (query['spx'] != null) 'spiderX': query['spx']!,
      if (query['ech'] != null) 'echConfigList': query['ech']!,
      if (query['echForceQuery'] != null)
        'echForceQuery': query['echForceQuery']!,
      if (query['ech_force_query'] != null)
        'echForceQuery': query['ech_force_query']!,
      'tlsSecurity': query['security'] ?? 'none',
    };
    final label = uri.fragment.isEmpty
        ? '${protocol.name.toUpperCase()} · $host'
        : Uri.decodeComponent(uri.fragment);
    final metadata = XraySubscriptionMetadata.uri(uri);
    return VpnNode(
      id: _id(subscriptionId, source),
      xrayOutbound: metadata.outbound,
      sourceMetadata: metadata.source,
      importWarnings: metadata.warnings,
      subscriptionId: subscriptionId,
      name: label,
      protocol: protocol,
      host: host,
      port: port,
      credentials: credentials,
      transport: transport,
      sni: query['sni'] ?? query['serverName'],
      fingerprint: query['fp'],
    );
  }

  String _normalizeTransport(String value) =>
      switch (value.toLowerCase().replaceAll(RegExp(r'[-_\s]'), '')) {
        'websocket' || 'ws' => 'ws',
        'xhttp' || 'splithttp' => 'xhttp',
        'httpupgrade' || 'httpup' => 'httpupgrade',
        'grpc' || 'gun' => 'grpc',
        'tcp' || 'raw' => 'tcp',
        _ => value.toLowerCase().trim(),
      };

  Map<String, String> _stringMap(Map values) => {
    for (final entry in values.entries)
      if (entry.value != null) entry.key.toString(): entry.value.toString(),
  };

  Map<String, dynamic>? _mapValue(Object? value) {
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value);
  }

  /// Converts an Xray-native outbound into the neutral map consumed by the
  /// Clash/URI normalizer below. Native profiles use `settings.vnext` and
  /// `streamSettings`, so treating them as Clash rows would silently drop the
  /// endpoint and its transport metadata.
  Map<String, dynamic> _normalizeXrayOutbound(Map<String, dynamic> source) {
    if (source['protocol'] == null || source['settings'] is! Map) {
      return source;
    }
    final protocol = source['protocol'].toString().toLowerCase();
    final settings = Map<String, dynamic>.from(source['settings'] as Map);
    final stream = source['streamSettings'] is Map
        ? Map<String, dynamic>.from(source['streamSettings'] as Map)
        : const <String, dynamic>{};
    Map<String, dynamic> server = const <String, dynamic>{};
    Map<String, dynamic> user = const <String, dynamic>{};
    if (protocol == 'vless' || protocol == 'vmess') {
      final vnext = settings['vnext'];
      if (vnext is List && vnext.isNotEmpty && vnext.first is Map) {
        server = Map<String, dynamic>.from(vnext.first as Map);
        final users = server['users'];
        if (users is List && users.isNotEmpty && users.first is Map) {
          user = Map<String, dynamic>.from(users.first as Map);
        }
      }
      // Xray also accepts a single-server VLESS/VMess settings object. This
      // is the form emitted by the profile pasted by the user.
      if (server.isEmpty && settings['address'] != null) {
        server = {'address': settings['address'], 'port': settings['port']};
        user = {
          'id': settings['id'],
          'encryption': settings['encryption'],
          'security': settings['security'],
          'flow': settings['flow'],
        };
      }
    }
    if ((protocol == 'trojan' || protocol == 'shadowsocks') &&
        settings['servers'] is List) {
      final servers = settings['servers'] as List;
      if (servers.length != 1 || servers.first is! Map) {
        throw const SubscriptionFormatException(
          'Multi-server outbound requires explicit support.',
        );
      }
      server = Map<String, dynamic>.from(servers.first as Map);
    }
    if ((protocol == 'hysteria' || protocol == 'hysteria2') &&
        settings['address'] != null) {
      server = {'address': settings['address'], 'port': settings['port']};
    }
    if (server.isEmpty) return source;
    final normalized = <String, dynamic>{
      'type': protocol,
      '_xrayOutbound': source,
      'tag': source['tag'],
      'server': server['address'],
      'server_port': server['port'],
      'uuid': user['id'],
      'password': server['password'] ?? user['id'],
      'method': server['method'],
      'encryption': user['encryption'],
      'flow': user['flow'],
      'alterId': user['alterId'],
      'cipher': user['security'],
      'network': stream['network'],
      'streamSettings': stream,
      'tls': stream['security'] == 'tls',
      'servername': (stream['tlsSettings'] as Map?)?['serverName'],
      'alpn': (stream['tlsSettings'] as Map?)?['alpn'],
      'client-fingerprint':
          (stream['tlsSettings'] as Map?)?['fingerprint'] ??
          (stream['realitySettings'] as Map?)?['fingerprint'],
      'reality': stream['realitySettings'],
      'xhttpExtra': (stream['xhttpSettings'] as Map?)?['extra'] == null
          ? null
          : jsonEncode((stream['xhttpSettings'] as Map)['extra']),
      'hysteriaAuth':
          (stream['hysteriaSettings'] as Map?)?['auth'] ?? settings['auth'],
      'hysteriaVersion':
          (stream['hysteriaSettings'] as Map?)?['version'] ??
          settings['version'],
      'hysteriaMask': stream['finalmask'] == null
          ? null
          : jsonEncode(stream['finalmask']),
    };
    return normalized;
  }

  String? _stringValue(Object? value) {
    if (value == null) return null;
    if (value is List) {
      final values = value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      return values.isEmpty ? null : values.join(',');
    }
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  VpnNode _parseShadowsocks(String source, String subscriptionId) {
    final uri = Uri.parse(source);
    var userInfo = Uri.decodeComponent(uri.userInfo);
    var host = uri.host;
    var port = uri.port;
    if (host.isEmpty || port == 0) {
      final body = source
          .substring('ss://'.length)
          .split('#')
          .first
          .split('?')
          .first;
      final decoded = utf8.decode(base64Decode(base64.normalize(body)));
      final at = decoded.lastIndexOf('@');
      if (at <= 0) {
        throw const FormatException('Invalid Shadowsocks authority.');
      }
      userInfo = decoded.substring(0, at);
      final authority = Uri.parse('ss://${decoded.substring(at + 1)}');
      host = authority.host;
      port = authority.port;
    }
    final separator = userInfo.indexOf(':');
    if (separator <= 0 || host.isEmpty || port < 1 || port > 65535) {
      throw const SubscriptionFormatException('Invalid Shadowsocks node.');
    }
    final label = uri.fragment.isEmpty
        ? 'Shadowsocks · $host'
        : Uri.decodeComponent(uri.fragment);
    return VpnNode(
      id: _id(subscriptionId, source),
      subscriptionId: subscriptionId,
      name: label,
      protocol: ProxyProtocol.shadowsocks,
      sourceMetadata: {
        'format': 'uri',
        'fields': Map<String, String>.from(uri.queryParameters),
      },
      importWarnings: [
        if (uri.queryParameters.isNotEmpty)
          'Unsupported Shadowsocks connection fields: ${uri.queryParameters.keys.join(', ')}.',
      ],
      host: host,
      port: port,
      credentials: {
        'method': userInfo.substring(0, separator),
        'password': userInfo.substring(separator + 1),
      },
    );
  }

  VpnNode _parseVmess(String source, String subscriptionId) {
    final encoded = source
        .substring(source.indexOf('://') + 3)
        .split('#')
        .first;
    final jsonText = utf8.decode(base64Decode(base64.normalize(encoded)));
    final data = Map<String, dynamic>.from(jsonDecode(jsonText) as Map);
    final host = (data['add'] ?? '').toString();
    final port = int.tryParse((data['port'] ?? '').toString()) ?? 0;
    final uuid = (data['id'] ?? '').toString();
    if (host.isEmpty || port < 1 || port > 65535 || uuid.isEmpty) {
      throw const SubscriptionFormatException('Invalid VMess node.');
    }
    final metadata = XraySubscriptionMetadata.vmess(data);
    return VpnNode(
      id: _id(subscriptionId, source),
      subscriptionId: subscriptionId,
      xrayOutbound: metadata.outbound,
      sourceMetadata: metadata.source,
      importWarnings: metadata.warnings,
      name: (data['ps'] as String?)?.trim().isNotEmpty == true
          ? data['ps'] as String
          : 'VMess · $host',
      protocol: ProxyProtocol.vmess,
      host: host,
      port: port,
      credentials: {
        'uuid': uuid,
        'alterId': (data['aid'] ?? '0').toString(),
        'security': (data['scy'] ?? 'auto').toString(),
        'tlsSecurity': (data['tls'] ?? '').toString().isNotEmpty
            ? 'tls'
            : 'none',
        if ((data['path'] ?? '').toString().isNotEmpty)
          'path': data['path'].toString(),
        if ((data['host'] ?? '').toString().isNotEmpty)
          'hostHeader': data['host'].toString(),
        if (data['alpn'] != null) 'alpn': data['alpn'].toString(),
        if (data['net'] == 'grpc' && data['path'] != null)
          'serviceName': data['path'].toString(),
      },
      transport: (data['net'] ?? 'tcp').toString(),
      sni: (data['sni'] as String?)?.trim().isNotEmpty == true
          ? data['sni'] as String
          : (data['host'] as String?)?.trim(),
      fingerprint: data['fp']?.toString(),
    );
  }

  String _id(String subscriptionId, String value) {
    // Stable, non-secret identifier. Do not use this hash as authentication.
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode('$subscriptionId\u0000$value')) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
