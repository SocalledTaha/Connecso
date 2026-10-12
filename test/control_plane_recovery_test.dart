import 'dart:convert';

import 'package:connecso_client/domain/services/control_plane_recovery.dart';
import 'package:connecso_client/platform/android/ed25519_recovery_manifest_verifier.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30, 12);

  test(
    'accepts only signed HTTPS endpoints inside the manifest allowlist',
    () async {
      final manifest = await validateRecoveryManifest(
        payload: _payload(
          endpoints: [
            {'id': 'primary', 'url': 'https://pool.example.com/recover'},
            {
              'id': 'backup',
              'url': 'https://east.recovery.example.com/v1',
              'priority': 10,
            },
          ],
        ),
        signature: 'valid-signature',
        verifier: const _Verifier(accept: true),
        now: now,
      );

      expect(manifest.version, 1);
      expect(manifest.endpoints, hasLength(2));
      expect(manifest.endpoints.last.priority, 10);
      expect(manifest.destinationAllowlist, contains('example.com'));
    },
  );

  test(
    'rejects invalid signatures, cleartext, and hosts outside allowlist',
    () async {
      final signatureFailure = validateRecoveryManifest(
        payload: _payload(),
        signature: 'bad-signature',
        verifier: const _Verifier(accept: false),
        now: now,
      );
      await expectLater(signatureFailure, throwsFormatException);

      final cleartext = validateRecoveryManifest(
        payload: _payload(
          endpoints: [
            {'id': 'primary', 'url': 'http://pool.example.com/recover'},
          ],
        ),
        signature: 'valid-signature',
        verifier: const _Verifier(accept: true),
        now: now,
      );
      await expectLater(cleartext, throwsFormatException);

      final foreignHost = validateRecoveryManifest(
        payload: _payload(
          endpoints: [
            {'id': 'primary', 'url': 'https://pool.attacker.invalid/recover'},
          ],
        ),
        signature: 'valid-signature',
        verifier: const _Verifier(accept: true),
        now: now,
      );
      await expectLater(foreignHost, throwsFormatException);
    },
  );

  test(
    'does not replace cached recovery data until verification succeeds',
    () async {
      final store = _Store();
      await expectLater(
        verifyAndReplaceRecoveryManifest(
          payload: _payload(),
          signature: 'invalid',
          verifier: const _Verifier(accept: false),
          store: store,
          now: now,
        ),
        throwsFormatException,
      );
      expect(store.replacements, 0);

      await verifyAndReplaceRecoveryManifest(
        payload: _payload(),
        signature: 'valid',
        verifier: const _Verifier(accept: true),
        store: store,
        now: now,
      );
      expect(store.replacements, 1);
    },
  );

  test('rejects expired manifests', () async {
    await expectLater(
      validateRecoveryManifest(
        payload: _payload(expiresAt: DateTime.utc(2026, 9, 29)),
        signature: 'valid',
        verifier: const _Verifier(accept: true),
        now: now,
      ),
      throwsFormatException,
    );
  });

  test('verifies Ed25519 signatures with the pinned public key', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(List.filled(32, 7));
    final publicKey = await keyPair.extractPublicKey();
    final payload = _payload();
    final signed = await algorithm.sign(utf8.encode(payload), keyPair: keyPair);
    final signature = base64Url.encode(signed.bytes).replaceAll('=', '');
    final verifier = Ed25519RecoveryManifestVerifier(publicKey.bytes);

    expect(await verifier.verify(payload, signature), isTrue);
    expect(await verifier.verify('$payload ', signature), isFalse);
    expect(await verifier.verify(payload, 'not-a-signature'), isFalse);
  });
}

String _payload({
  List<Map<String, Object?>> endpoints = const [
    {'id': 'primary', 'url': 'https://pool.example.com/recover'},
  ],
  DateTime? expiresAt,
}) => jsonEncode({
  'version': 1,
  'issuedAt': DateTime.utc(2026, 9, 30, 10).toIso8601String(),
  'expiresAt': (expiresAt ?? DateTime.utc(2026, 10, 1)).toIso8601String(),
  'destinationAllowlist': ['example.com'],
  'endpoints': endpoints,
});

class _Verifier implements RecoveryManifestVerifier {
  const _Verifier({required this.accept});
  final bool accept;

  @override
  Future<bool> verify(String manifestPayload, String signature) async => accept;
}

class _Store implements RecoveryManifestStore {
  int replacements = 0;

  @override
  Future<void> replace(RecoveryManifest manifest) async {
    replacements++;
  }
}
