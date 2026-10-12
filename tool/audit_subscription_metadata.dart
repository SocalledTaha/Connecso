import 'dart:convert';
import 'dart:io';
import '../lib/data/parsers/subscription_parser.dart';
import '../lib/domain/models/vpn_node.dart';
import '../lib/domain/services/xray_config_builder.dart';

// Local read-only audit of a supplied subscription. Prints counts/field names
// only; private generated configs stay in the explicitly supplied directory.
void main(List<String> args) {
  if (args.length != 2) throw ArgumentError('Usage: dart run tool/audit_subscription_metadata.dart <input> <private-output-directory>');
  final nodes = const SubscriptionParser().parse(File(args[0]).readAsStringSync(), subscriptionId:'metadata-audit');
  final roundTrip = decodeNodes(encodeNodes(nodes));
  final output = Directory(args[1])..createSync(recursive:true);
  final protocols = <String,int>{};
  final warnings = <String>{};
  Map<String,Object?>? plumbing;
  var structured = 0;
  var checked = 0;
  for (var index=0; index<roundTrip.length; index++) {
    final node=roundTrip[index];
    if (jsonEncode(node.xrayOutbound) != jsonEncode(nodes[index].xrayOutbound) ||
        jsonEncode(node.sourceMetadata) != jsonEncode(nodes[index].sourceMetadata)) {
      throw StateError('Cache changed metadata for node ${node.id}.');
    }
    protocols.update('${node.protocol.name}/${node.transport}', (v)=>v+1, ifAbsent:()=>1);
    warnings.addAll(node.importWarnings);
    final config=const XrayConfigBuilder().build(node);
    final outbound=(config['outbounds'] as List).first as Map;
    if (node.xrayOutbound.isNotEmpty) structured++;
    _contains(outbound, node.xrayOutbound, path:'outbound');
    final infrastructure=Map<String,Object?>.from(config)..remove('outbounds');
    if (plumbing != null && jsonEncode(plumbing)!=jsonEncode(infrastructure)) throw StateError('Local VPN plumbing differs by node.');
    plumbing ??= infrastructure;
    File('${output.path}/node-${node.id}.json').writeAsStringSync(jsonEncode(config));
    checked++;
  }
  // Synthetic native profile validates preservation of types, arrays, nested
  // TLS settings, explicit false/empty, custom headers, and outbound settings.
  final native={'outbounds':[{
    'tag':'reference', 'protocol':'vless',
    'settings':{'address':'example.invalid','port':443,'id':'00000000-0000-4000-8000-000000000001','encryption':'none','flow':'xtls-rprx-vision','email':'local-fixture'},
    'streamSettings':{'network':'ws','security':'tls',
      'tlsSettings':{'serverName':'example.invalid','fingerprint':'firefox','allowInsecure':false,'alpn':['http/1.1'],'settings':{'fingerprint':'chrome','pinnedPeerCertSha256':[]}},
      'wsSettings':{'host':'example.invalid','path':'/','heartbeatPeriod':0,'acceptProxyProtocol':false,'headers':{'X-Audit':'fixture'}}},
    'mux':{'enabled':false,'concurrency':-1},
  }]};
  final fixture=const SubscriptionParser().parse(jsonEncode(native),subscriptionId:'fixture').single;
  final built=(const XrayConfigBuilder().build(fixture)['outbounds'] as List).first as Map;
  _contains(built,(native['outbounds'] as List).first as Map,path:'native');
  print('Audit OK nodes=$checked structured=$structured cacheRoundTrip=OK fixedInboundAndRouting=OK nativeTypedMetadata=OK');
  print('Protocol counts: ${jsonEncode(protocols)}');
  for (final warning in warnings) { print('Diagnostic: $warning'); }
}

void _contains(Object? actual,Object? expected,{required String path}) {
  if(expected is Map) {
    if(actual is! Map) throw StateError('Metadata object type changed at $path.');
    for(final key in expected.keys) {
      if(key=='tag' && (path=='outbound' || path=='native')) continue;
      if(!actual.containsKey(key)) throw StateError('Metadata missing at $path.$key.');
      _contains(actual[key],expected[key],path:'$path.$key');
    }
  } else if(jsonEncode(actual)!=jsonEncode(expected)) {
    throw StateError('Metadata changed at $path.');
  }
}
