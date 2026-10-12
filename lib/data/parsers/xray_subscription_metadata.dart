import 'dart:convert';

/// Own conversion, not copied from another client. Values stay private in the
/// encrypted node cache; diagnostics only contain field names.
class XraySubscriptionMetadata {
  XraySubscriptionMetadata(
    this.outbound,
    this.source, [
    this.warnings = const [],
  ]);
  final Map<String, Object?> outbound;
  final Map<String, Object?> source;
  final List<String> warnings;

  static Map<String, Object?> object(Object? value) => value is Map
      ? Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map)
      : <String, Object?>{};

  static Map<String, Object?> jsonObject(String text, String field) {
    try {
      final value = jsonDecode(text);
      if (value is Map) return object(value);
    } catch (_) {
      /* Never echo the supplied value (may contain credentials). */
    }
    throw FormatException('Invalid JSON object in $field.');
  }

  factory XraySubscriptionMetadata.uri(Uri uri, {bool hysteria = false}) {
    final q = uri.queryParameters;
    final stream = <String, Object?>{};
    final tls = <String, Object?>{};
    final reality = <String, Object?>{};
    final transport =
        (q['type'] ?? q['network'] ?? (hysteria ? 'hysteria' : 'tcp'))
            .toLowerCase();
    final security = q['security'] ?? (hysteria ? 'tls' : 'none');
    stream['security'] = security;
    void text(Map<String, Object?> target, String key, List<String> aliases) {
      for (final alias in aliases) {
        if (q.containsKey(alias)) {
          target[key] = q[alias];
          return;
        }
      }
    }

    void boolean(
      Map<String, Object?> target,
      String key,
      List<String> aliases,
    ) {
      for (final alias in aliases) {
        if (!q.containsKey(alias)) continue;
        final value = q[alias]!.toLowerCase();
        if (!const ['0', '1', 'true', 'false'].contains(value)) {
          throw FormatException('Invalid boolean field: $alias.');
        }
        target[key] = value == '1' || value == 'true';
        return;
      }
    }

    text(tls, 'serverName', ['sni', 'serverName']);
    text(tls, 'fingerprint', ['fp', 'fingerprint']);
    text(tls, 'echConfigList', ['ech', 'echConfigList']);
    // ECH links in the wild commonly publish only the config list. The
    // working CONNECSO/Xray profiles require the resolver to be queried when
    // the list is present; preserve an explicit provider value when supplied.
    if (tls['echConfigList'] != null && !tls.containsKey('echForceQuery')) {
      tls['echForceQuery'] = 'full';
    }
    // Providers use both the Xray JSON spelling and the URI spelling for
    // forcing an ECH lookup. Keep the value in the native tlsSettings map;
    // dropping it makes otherwise identical WS/XHTTP nodes fail only on
    // networks that require ECH.
    text(tls, 'echForceQuery', ['echForceQuery', 'ech_force_query']);
    text(tls, 'verifyPeerCertByName', ['verifyPeerCertByName']);
    for (final key in ['minVersion', 'maxVersion', 'cipherSuites']) {
      text(tls, key, [key]);
    }
    boolean(tls, 'allowInsecure', ['allowInsecure', 'insecure']);
    boolean(tls, 'disableSystemRoot', ['disableSystemRoot']);
    boolean(tls, 'enableSessionResumption', ['enableSessionResumption']);
    if (q.containsKey('alpn'))
      tls['alpn'] = q['alpn']!.split(',').map((v) => v.trim()).toList();
    if (q.containsKey('pinSHA256'))
      tls['pinnedPeerCertSha256'] = q['pinSHA256']!.split(',');
    if (q.containsKey('pinnedPeerCertSha256'))
      tls['pinnedPeerCertSha256'] = q['pinnedPeerCertSha256']!.split(',');
    text(reality, 'serverName', ['sni', 'serverName']);
    text(reality, 'fingerprint', ['fp', 'fingerprint']);
    text(reality, 'publicKey', ['pbk', 'publicKey']);
    text(reality, 'shortId', ['sid', 'shortId']);
    text(reality, 'spiderX', ['spx', 'spiderX']);
    text(reality, 'mldsa65Verify', ['mldsa65Verify']);
    if (q.containsKey('alpn')) reality['alpn'] = tls['alpn'];
    if (security == 'tls') stream['tlsSettings'] = tls;
    if (security == 'reality') stream['realitySettings'] = reality;
    final opts = <String, Object?>{};
    text(opts, 'path', ['path']);
    text(opts, 'host', ['host']);
    switch (transport) {
      case 'ws':
      case 'websocket':
        if (q.containsKey('headers'))
          opts['headers'] = jsonObject(q['headers']!, 'headers');
        boolean(opts, 'acceptProxyProtocol', ['acceptProxyProtocol']);
        if (q.containsKey('heartbeatPeriod'))
          opts['heartbeatPeriod'] = _integer(
            q['heartbeatPeriod'],
            'heartbeatPeriod',
          );
        stream['wsSettings'] = opts;
      case 'xhttp':
      case 'splithttp':
        text(opts, 'mode', ['mode']);
        final extra = q.containsKey('extra')
            ? jsonObject(q['extra']!, 'extra')
            : <String, Object?>{};
        if (q.containsKey('x_padding_bytes'))
          extra.putIfAbsent('xPaddingBytes', () => q['x_padding_bytes']);
        if (q.containsKey('xPaddingBytes'))
          extra['xPaddingBytes'] = q['xPaddingBytes'];
        if (q.containsKey('xmux'))
          extra['xmux'] = jsonObject(q['xmux']!, 'xmux');
        if (extra.isNotEmpty || q.containsKey('extra')) opts['extra'] = extra;
        stream['xhttpSettings'] = opts;
      case 'httpupgrade':
        stream['httpupgradeSettings'] = opts;
      case 'grpc':
      case 'gun':
        final grpc = <String, Object?>{};
        text(grpc, 'serviceName', ['serviceName']);
        text(grpc, 'authority', ['authority']);
        boolean(grpc, 'multiMode', ['multiMode']);
        if (q['mode'] == 'multi') grpc['multiMode'] = true;
        for (final key in [
          'idle_timeout',
          'health_check_timeout',
          'initial_windows_size',
        ]) {
          if (q.containsKey(key)) grpc[key] = _integer(q[key], key);
        }
        stream['grpcSettings'] = grpc;
      case 'tcp':
      case 'raw':
        if (q['headerType'] == 'http') {
          stream['tcpSettings'] = {
            'header': {
              'type': 'http',
              'request': {
                if (q.containsKey('path')) 'path': q['path']!.split(','),
                if (q.containsKey('host'))
                  'headers': {'Host': q['host']!.split(',')},
              },
            },
          };
        }
    }
    final outbound = <String, Object?>{'streamSettings': stream};
    if (q.containsKey('mux')) outbound['mux'] = jsonObject(q['mux']!, 'mux');
    if (q.containsKey('sockopt'))
      stream['sockopt'] = jsonObject(q['sockopt']!, 'sockopt');
    if (q.containsKey('finalmask'))
      stream['finalmask'] = jsonObject(q['finalmask']!, 'finalmask');
    final known = <String>{
      'type',
      'network',
      'security',
      'sni',
      'serverName',
      'fp',
      'fingerprint',
      'alpn',
      'encryption',
      'flow',
      'pbk',
      'publicKey',
      'sid',
      'shortId',
      'spx',
      'spiderX',
      'mldsa65Verify',
      'host',
      'path',
      'headers',
      'serviceName',
      'authority',
      'multiMode',
      'mode',
      'extra',
      'x_padding_bytes',
      'xPaddingBytes',
      'xmux',
      'ech',
      'echConfigList',
      'echForceQuery',
      'ech_force_query',
      'pinSHA256',
      'pinnedPeerCertSha256',
      'verifyPeerCertByName',
      'allowInsecure',
      'insecure',
      'minVersion',
      'maxVersion',
      'cipherSuites',
      'disableSystemRoot',
      'enableSessionResumption',
      'acceptProxyProtocol',
      'heartbeatPeriod',
      'mux',
      'sockopt',
      'finalmask',
      'headerType',
      'idle_timeout',
      'health_check_timeout',
      'initial_windows_size',
      if (hysteria) ...['obfs', 'obfs-password'],
    };
    final warnings = <String>[];
    if (q.containsKey('support-x25519mlkem768')) {
      known.add('support-x25519mlkem768');
      warnings.add(
        'URI support-x25519mlkem768: client capability hint retained; not an Xray connection field.',
      );
    }
    final unsupported = q.keys.where((k) => !known.contains(k)).toList()
      ..sort();
    if (unsupported.isNotEmpty)
      warnings.add(
        'Unsupported URI connection fields: ${unsupported.join(', ')}.',
      );
    return XraySubscriptionMetadata(outbound, {
      'format': 'uri',
      'query': q,
    }, warnings);
  }

  factory XraySubscriptionMetadata.map(Map<String, dynamic> row) {
    if (row['_xrayOutbound'] is Map) {
      return XraySubscriptionMetadata(object(row['_xrayOutbound']), {
        'format': 'xray',
        'outbound': object(row['_xrayOutbound']),
      });
    }
    final out = <String, Object?>{};
    final stream = object(row['streamSettings']);
    final tls = object(stream['tlsSettings']);
    final tlsSource = object(row['tls']);
    void set(Map<String, Object?> target, String key, Object? value) {
      if (value != null) target.putIfAbsent(key, () => value);
    }

    set(
      tls,
      'serverName',
      tlsSource['server_name'] ??
          tlsSource['serverName'] ??
          row['sni'] ??
          row['servername'] ??
          row['serverName'] ??
          row['server-name'],
    );
    set(
      tls,
      'fingerprint',
      object(tlsSource['utls'])['fingerprint'] ?? row['client-fingerprint'],
    );
    set(tls, 'alpn', tlsSource['alpn'] ?? row['alpn']);
    set(tls, 'allowInsecure', tlsSource['insecure'] ?? row['skip-cert-verify']);
    set(tls, 'pinnedPeerCertSha256', tlsSource['pinned_peer_cert_sha256']);
    set(
      tls,
      'echConfigList',
      object(tlsSource['ech'])['config'] ?? row['echConfigList'],
    );
    set(
      tls,
      'echForceQuery',
      object(tlsSource['ech'])['force_query'] ??
          object(tlsSource['ech'])['forceQuery'] ??
          row['echForceQuery'] ??
          row['ech_force_query'],
    );
    if (tls.isNotEmpty) stream['tlsSettings'] = tls;
    final reality = object(stream['realitySettings']);
    final realitySource = object(
      tlsSource['reality'] ?? row['reality'] ?? row['reality-opts'],
    );
    for (final aliases in const {
      'publicKey': ['public_key', 'public-key', 'publicKey'],
      'shortId': ['short_id', 'short-id', 'shortId'],
      'spiderX': ['spider_x', 'spider-x', 'spiderX'],
      'mldsa65Verify': ['mldsa65Verify'],
      'serverName': ['server_name', 'serverName'],
      'fingerprint': ['fingerprint'],
      'alpn': ['alpn'],
    }.entries) {
      for (final alias in aliases.value) {
        set(reality, aliases.key, realitySource[alias]);
      }
    }
    if (reality.isNotEmpty) stream['realitySettings'] = reality;
    final transport = object(row['transport']);
    for (final pair in const [
      ('wsSettings', 'ws-opts'),
      ('xhttpSettings', 'xhttp-opts'),
      ('grpcSettings', 'grpc-opts'),
    ]) {
      final opts = object(row[pair.$2] ?? row[pair.$2.replaceAll('-', '_')]);
      if (opts.isNotEmpty) stream.putIfAbsent(pair.$1, () => opts);
    }
    final xhttp = object(stream['xhttpSettings']);
    final extra = row['xhttpExtra'] ?? transport['extra'];
    if (extra != null)
      xhttp['extra'] = extra is String
          ? jsonObject(extra, 'xhttpExtra')
          : object(extra);
    if (xhttp.isNotEmpty) stream['xhttpSettings'] = xhttp;
    if (row['mux'] is Map) out['mux'] = object(row['mux']);
    if (row['finalmask'] is Map) stream['finalmask'] = object(row['finalmask']);
    if (row['sockopt'] is Map) stream['sockopt'] = object(row['sockopt']);
    out['streamSettings'] = stream;
    final known = <String>{
      'type',
      'name',
      'tag',
      'server',
      'server_port',
      'port',
      'uuid',
      'password',
      'auth',
      'hysteriaAuth',
      'hysteriaVersion',
      'hysteriaMask',
      'version',
      'method',
      'cipher',
      'alterId',
      'alter-id',
      'encryption',
      'flow',
      'network',
      'transport',
      'streamSettings',
      'tls',
      'reality',
      'reality-opts',
      'servername',
      'serverName',
      'server-name',
      'sni',
      'client-fingerprint',
      'alpn',
      'xhttpExtra',
      'ws-opts',
      'ws_opts',
      'xhttp-opts',
      'xhttp_opts',
      'grpc-opts',
      'grpc_opts',
      'mux',
      'sockopt',
      'finalmask',
      'skip-cert-verify',
      'echConfigList',
      'echForceQuery',
      'ech_force_query',
      'obfs',
      'obfs-password',
    };
    final warnings = <String>[];
    final unsupportedReality =
        realitySource.keys
            .where(
              (key) => !const {
                'enabled',
                'public_key',
                'public-key',
                'publicKey',
                'short_id',
                'short-id',
                'shortId',
                'spider_x',
                'spider-x',
                'spiderX',
                'mldsa65Verify',
                'server_name',
                'serverName',
                'fingerprint',
                'alpn',
              }.contains(key),
            )
            .toList()
          ..sort();
    if (unsupportedReality.isNotEmpty)
      warnings.add(
        'Unsupported map Reality fields: ${unsupportedReality.join(', ')}.',
      );
    final unsupported = row.keys.where((key) => !known.contains(key)).toList()
      ..sort();
    if (unsupported.isNotEmpty)
      warnings.add(
        'Unsupported map connection fields: ${unsupported.join(', ')}.',
      );
    // Non-Xray formats need explicit conversion, not stringification of objects.
    final tlsKeys = <String>{
      'enabled',
      'server_name',
      'serverName',
      'alpn',
      'utls',
      'insecure',
      'reality',
      'ech',
      'echConfigList',
      'echForceQuery',
      'ech_force_query',
      'pinned_peer_cert_sha256',
    };
    final unsupportedTls =
        tlsSource.keys.where((key) => !tlsKeys.contains(key)).toList()..sort();
    if (unsupportedTls.isNotEmpty)
      warnings.add('Unsupported map TLS fields: ${unsupportedTls.join(', ')}.');
    final grpc = object(stream['grpcSettings']);
    if (grpc.containsKey('grpc-service-name'))
      grpc['serviceName'] = grpc.remove('grpc-service-name');
    if (grpc.isNotEmpty) stream['grpcSettings'] = grpc;
    if ((row['type'] == 'hysteria2' || row['type'] == 'hysteria') &&
        row['obfs'] != null) {
      if (row['obfs'] != 'salamander' || row['obfs-password'] == null) {
        warnings.add('Unsupported map obfuscation fields.');
      } else {
        stream['finalmask'] = {
          'udp': [
            {
              'type': 'salamander',
              'settings': {'password': row['obfs-password']},
            },
          ],
        };
      }
    }
    return XraySubscriptionMetadata(out, {
      'format': 'map',
      'fields': object(row),
    }, warnings);
  }

  factory XraySubscriptionMetadata.vmess(Map<String, dynamic> data) {
    final q = <String, String>{
      'type': (data['net'] ?? 'tcp').toString(),
      'security': (data['tls'] ?? 'none').toString().isEmpty
          ? 'none'
          : (data['tls'] ?? 'none').toString(),
      for (final key in [
        'path',
        'host',
        'sni',
        'fp',
        'alpn',
        'allowInsecure',
        'headerType',
        'serviceName',
      ])
        if (data.containsKey(key)) key: data[key].toString(),
    };
    if (data['type'] == 'http') q['headerType'] = 'http';
    if (data['net'] == 'grpc' &&
        !q.containsKey('serviceName') &&
        data['path'] != null)
      q['serviceName'] = data['path'].toString();
    final meta = XraySubscriptionMetadata.uri(Uri(queryParameters: q));
    final unknown =
        data.keys
            .where(
              (key) => !const {
                'v',
                'ps',
                'add',
                'port',
                'id',
                'aid',
                'scy',
                'net',
                'tls',
                'type',
                'path',
                'host',
                'sni',
                'fp',
                'alpn',
                'allowInsecure',
                'headerType',
                'serviceName',
              }.contains(key),
            )
            .toList()
          ..sort();
    return XraySubscriptionMetadata(
      meta.outbound,
      {'format': 'vmess', 'fields': object(data)},
      [
        ...meta.warnings,
        if (unknown.isNotEmpty)
          'Unsupported VMess connection fields: ${unknown.join(', ')}.',
      ],
    );
  }

  static int _integer(String? text, String field) =>
      int.tryParse(text ?? '') ??
      (throw FormatException('Invalid integer field: $field.'));
}
