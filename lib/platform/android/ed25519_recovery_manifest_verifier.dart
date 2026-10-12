import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../domain/services/control_plane_recovery.dart';

/// Verifies canonical base64url Ed25519 signatures against an injected pinned
/// public key. The public key is not secret; no signing key belongs in the app.
class Ed25519RecoveryManifestVerifier implements RecoveryManifestVerifier {
  Ed25519RecoveryManifestVerifier(List<int> publicKeyBytes)
    : _publicKey = SimplePublicKey(
        List<int>.unmodifiable(publicKeyBytes),
        type: KeyPairType.ed25519,
      ) {
    if (publicKeyBytes.length != 32) {
      throw ArgumentError.value(
        publicKeyBytes.length,
        'publicKeyBytes.length',
        'Ed25519 public keys must be 32 bytes.',
      );
    }
  }

  final SimplePublicKey _publicKey;
  static final _algorithm = Ed25519();

  @override
  Future<bool> verify(String manifestPayload, String signature) async {
    if (signature.isEmpty || signature.contains('=')) return false;
    try {
      final bytes = base64Url.decode(base64Url.normalize(signature));
      if (bytes.length != 64) return false;
      return await _algorithm.verify(
        utf8.encode(manifestPayload),
        signature: Signature(bytes, publicKey: _publicKey),
      );
    } on FormatException {
      return false;
    }
  }
}
