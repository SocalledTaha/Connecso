import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stable, privacy-preserving client identity sent with subscription requests.
/// It is an app-install random ID, never a hardware serial, IMEI, or MAC.
class SubscriptionRequestIdentity {
  SubscriptionRequestIdentity(this._storage);

  static const _storageKey = 'subscription_request_hwid_v1';
  static const _clientVersion = '0.2.5';

  final FlutterSecureStorage _storage;
  Future<String>? _hwidFuture;

  Future<Map<String, String>> headers() async {
    final osName = Platform.isAndroid
        ? 'Android'
        : Platform.isIOS
        ? 'iOS'
        : Platform.operatingSystem;
    final osVersion = Platform.operatingSystemVersion
        .replaceAll(RegExp(r'[\r\n]'), ' ')
        .trim();
    return {
      'User-Agent': 'Connecso Client/$_clientVersion ($osName)',
      'X-HWID': await (_hwidFuture ??= _loadOrCreateHwid()),
      'X-Device-OS': osName,
      if (osVersion.isNotEmpty) 'X-Ver-OS': osVersion,
    };
  }

  Future<String> _loadOrCreateHwid() async {
    final stored = await _storage.read(key: _storageKey);
    if (stored != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(stored)) {
      return stored;
    }
    final random = Random.secure();
    final id = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _storageKey, value: id);
    return id;
  }
}
