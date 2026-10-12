import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/models/vpn_node.dart';

abstract interface class SubscriptionCache {
  Future<List<VpnNode>> readNodes(String subscriptionId);
  Future<void> replaceNodes(
    String subscriptionId,
    List<VpnNode> validatedNodes,
  );
}

/// Initial encrypted cache. A full relational database with schema migrations
/// is a required follow-up before storing larger subscription histories.
class SecureSubscriptionCache implements SubscriptionCache {
  SecureSubscriptionCache(this._storage);
  static const _legacyKey = 'subscription_nodes_v1';
  static const _keyPrefix = 'subscription_nodes_v2_';
  final FlutterSecureStorage _storage;

  @override
  Future<List<VpnNode>> readNodes(String subscriptionId) async {
    _validateId(subscriptionId);
    final key = '$_keyPrefix$subscriptionId';
    var encoded = await _storage.read(key: key);
    // Upgrade the original single-subscription cache without discarding it.
    if (encoded == null && subscriptionId == 'primary') {
      encoded = await _storage.read(key: _legacyKey);
      if (encoded != null) await _storage.write(key: key, value: encoded);
    }
    if (encoded == null) return const [];
    try {
      return decodeNodes(encoded);
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  @override
  Future<void> replaceNodes(
    String subscriptionId,
    List<VpnNode> validatedNodes,
  ) async {
    _validateId(subscriptionId);
    if (validatedNodes.isEmpty) {
      throw ArgumentError.value(
        validatedNodes,
        'validatedNodes',
        'Must not be empty.',
      );
    }
    // Secure storage performs a single-key replacement. Build/validate the
    // complete candidate before this call so failure leaves the prior key intact.
    final candidate = encodeNodes(validatedNodes);
    await _storage.write(key: '$_keyPrefix$subscriptionId', value: candidate);
  }

  static void _validateId(String subscriptionId) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(subscriptionId)) {
      throw ArgumentError.value(subscriptionId, 'subscriptionId');
    }
  }
}
