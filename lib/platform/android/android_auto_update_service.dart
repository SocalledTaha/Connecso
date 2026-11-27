import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import 'android_vpn_adapter.dart';

class AndroidUpdatePackage {
  const AndroidUpdatePackage({
    required this.name,
    required this.url,
    required this.sizeBytes,
    this.sha256,
  });

  final String name;
  final Uri url;
  final int sizeBytes;
  final String? sha256;
}

class AndroidUpdateRelease {
  const AndroidUpdateRelease({
    required this.version,
    required this.tag,
    required this.changelog,
    required this.prerelease,
    required this.package,
  });

  final String version;
  final String tag;
  final String changelog;
  final bool prerelease;
  final AndroidUpdatePackage package;
}

class AndroidUpdateProgress {
  const AndroidUpdateProgress({
    required this.id,
    required this.receivedBytes,
    required this.totalBytes,
    required this.state,
  });

  final String id;
  final int receivedBytes;
  final int totalBytes;
  final String state;

  double get fraction => totalBytes <= 0
      ? 0
      : (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
}

class AndroidUpdateService {
  AndroidUpdateService(AndroidVpnAdapter vpn) {
    vpn.setAndroidUpdateProgressHandler(_handleNativeEvent);
  }

  static const _channel = MethodChannel('com.connecso.client/vpn');
  static const repository = 'SocalledTaha/Connecso';
  final _progress = StreamController<AndroidUpdateProgress>.broadcast();
  Stream<AndroidUpdateProgress> get progress => _progress.stream;

  void _handleNativeEvent(Map<Object?, Object?> values) {
    _progress.add(
      AndroidUpdateProgress(
        id: values['id']?.toString() ?? '',
        receivedBytes: (values['receivedBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (values['totalBytes'] as num?)?.toInt() ?? 0,
        state: values['state']?.toString() ?? 'downloading',
      ),
    );
  }

  Future<String> installedVersion() async {
    final info = await _channel.invokeMapMethod<Object?, Object?>(
      'androidBuildInfo',
    );
    final value = info?['versionName']?.toString().trim();
    return value == null || value.isEmpty ? '0.0.0' : value;
  }

  Future<String> get deviceAbi async {
    final info = await _channel.invokeMapMethod<Object?, Object?>(
      'androidBuildInfo',
    );
    return info?['primaryAbi']?.toString() ?? 'universal';
  }

  Future<AndroidUpdateRelease?> latestAndroidRelease({
    required bool includePrerelease,
    required bool useActiveRoute,
  }) async {
    final routeMethod = useActiveRoute
        ? 'fetchCurrentRouteSubscription'
        : 'fetchDirectSubscription';
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      routeMethod,
      {'url': 'https://api.github.com/repos/$repository/releases?per_page=100'},
    );
    final encoded = response?['bodyBase64']?.toString();
    if (encoded == null || encoded.isEmpty) {
      throw const FormatException('GitHub returned an empty release list.');
    }
    final decoded = jsonDecode(utf8.decode(base64Decode(encoded)));
    if (decoded is! List) {
      throw const FormatException('Unexpected GitHub release response.');
    }
    final abi = (await deviceAbi).toLowerCase();
    final releases =
        decoded
            .whereType<Map>()
            .where(
              (release) =>
                  release['draft'] != true &&
                  (includePrerelease || release['prerelease'] != true),
            )
            .toList()
          ..sort((a, b) {
            final aDate =
                DateTime.tryParse('${a['published_at']}') ?? DateTime(0);
            final bDate =
                DateTime.tryParse('${b['published_at']}') ?? DateTime(0);
            return bDate.compareTo(aDate);
          });
    for (final release in releases) {
      final rawAssets = release['assets'];
      if (rawAssets is! List) continue;
      final assets = rawAssets.whereType<Map>().where((asset) {
        final name = '${asset['name']}'.toLowerCase();
        return name.endsWith('.apk');
      }).toList();
      if (assets.isEmpty) continue;
      final matching = assets.where((asset) {
        final name = '${asset['name']}'.toLowerCase();
        return name.contains(abi) || name.contains('universal');
      }).toList();
      if (matching.isEmpty) continue;
      matching.sort((a, b) {
        final aName = '${a['name']}'.toLowerCase();
        final bName = '${b['name']}'.toLowerCase();
        return (aName.contains(abi) ? 0 : 1).compareTo(
          bName.contains(abi) ? 0 : 1,
        );
      });
      final asset = matching.first;
      final uri = Uri.tryParse('${asset['browser_download_url']}');
      if (uri == null || uri.scheme != 'https') continue;
      final tag = '${release['tag_name'] ?? ''}';
      final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
      if (version.isEmpty) continue;
      final digestValue = '${asset['digest'] ?? ''}';
      return AndroidUpdateRelease(
        version: version,
        tag: tag,
        changelog: '${release['body'] ?? ''}'.trim(),
        prerelease: release['prerelease'] == true,
        package: AndroidUpdatePackage(
          name: '${asset['name']}',
          url: uri,
          sizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
          sha256: digestValue.startsWith('sha256:')
              ? digestValue.substring(7)
              : null,
        ),
      );
    }
    return null;
  }

  int compareVersions(String left, String right) {
    final a = _versionParts(left);
    final b = _versionParts(right);
    for (var i = 0; i < 3; i++) {
      final difference = a.$1[i].compareTo(b.$1[i]);
      if (difference != 0) return difference;
    }
    if (a.$2.isEmpty && b.$2.isNotEmpty) return 1;
    if (a.$2.isNotEmpty && b.$2.isEmpty) return -1;
    return a.$2.compareTo(b.$2);
  }

  (List<int>, String) _versionParts(String version) {
    final normalized = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final split = normalized.split('-');
    final numbers = split.first
        .split('.')
        .map((value) => int.tryParse(value) ?? 0)
        .toList();
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return (
      numbers.take(3).toList(),
      split.length > 1 ? split.skip(1).join('-') : '',
    );
  }

  Future<File?> findDownloaded(AndroidUpdatePackage package) async {
    final path = await _channel.invokeMethod<String>('findAndroidUpdate', {
      'name': package.name,
    });
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (package.sizeBytes > 0 && length != package.sizeBytes) return null;
    if (package.sha256 != null && !await _matchesHash(file, package.sha256!)) {
      return null;
    }
    return file;
  }

  Future<String> get downloadDirectory async =>
      await _channel.invokeMethod<String>('androidUpdateDirectory') ?? '';

  Future<File?> findPartial(AndroidUpdatePackage package) async {
    final path = await _channel.invokeMethod<String>('findAndroidUpdate', {
      'name': package.name,
    });
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length <= 0 || (package.sizeBytes > 0 && length >= package.sizeBytes)) {
      return null;
    }
    return file;
  }

  Future<bool> _matchesHash(File file, String expected) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final actual = (await sink.hash()).bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return actual.toLowerCase() == expected.toLowerCase();
  }

  Future<Map<String, Object?>> startDownload({
    required String id,
    required AndroidUpdatePackage package,
    required bool useActiveRoute,
  }) async {
    final result = await _channel
        .invokeMapMethod<Object?, Object?>('startAndroidUpdateDownload', {
          'id': id,
          'url': package.url.toString(),
          'name': package.name,
          'sizeBytes': package.sizeBytes,
          'useActiveRoute': useActiveRoute,
        });
    final normalized =
        result?.map((key, value) => MapEntry('$key', value)) ??
        const <String, Object?>{};
    if (normalized['status'] == 'completed') {
      final path = normalized['path']?.toString();
      if (path == null || path.isEmpty) {
        throw const FormatException('The downloaded APK path is missing.');
      }
      final file = File(path);
      if (!await file.exists() ||
          (package.sizeBytes > 0 && await file.length() != package.sizeBytes) ||
          (package.sha256 != null &&
              !await _matchesHash(file, package.sha256!))) {
        await file.delete().catchError((_) => file);
        throw const FormatException(
          'The downloaded APK failed its size or SHA-256 check.',
        );
      }
    }
    return normalized;
  }

  Future<void> controlDownload(String id, String action) =>
      _channel.invokeMethod<void>('controlAndroidUpdateDownload', {
        'id': id,
        'action': action,
      });

  Future<void> install(File file) =>
      _channel.invokeMethod<void>('installAndroidUpdate', {'path': file.path});

  Future<void> openDownloaded(File file) =>
      _channel.invokeMethod<void>('openAndroidUpdate', {'path': file.path});

  Future<void> openProjectUrl(String url) =>
      _channel.invokeMethod<void>('openExternalUrl', {'url': url});

  void dispose() {
    _progress.close();
  }
}
