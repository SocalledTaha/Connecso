import 'dart:convert';

import 'package:connecso_client/data/parsers/subscription_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers profile title from response headers', () {
    expect(
      parseSubscriptionProfileTitle({
        'PROFILE-TITLE': '  Tehran Premium  ',
      }, '#profile-title: fallback\nvless://example'),
      'Tehran Premium',
    );
  });

  test('reads plain and base64 body profile title comments', () {
    expect(
      parseSubscriptionProfileTitle(
        const {},
        '#profile-title: Iran Plus\nvless://example',
      ),
      'Iran Plus',
    );
    expect(
      parseSubscriptionProfileTitle(
        const {},
        '#profile-title: base64:VGVocmFuIFZQTg==\nvless://example',
      ),
      'Tehran VPN',
    );
  });

  test('rejects malformed, empty, and overlong profile titles', () {
    expect(
      parseSubscriptionProfileTitle(const {}, '#profile-title: base64:%%%'),
      isNull,
    );
    expect(
      parseSubscriptionProfileTitle(const {}, '#profile-title:   '),
      isNull,
    );
    expect(
      parseSubscriptionProfileTitle(
        const {},
        '#profile-title: ${List.filled(26, 'x').join()}',
      ),
      isNull,
    );
  });

  test('reads account email only from explicit provider metadata', () {
    expect(
      parseSubscriptionAccountEmail({
        'SUBSCRIPTION-EMAIL': 'Hamid@example.com',
      }, 'vless://example#node@example.net'),
      'Hamid@example.com',
    );
    expect(
      parseSubscriptionAccountEmail(
        const {},
        '#email: base64:aGFtaWRAZXhhbXBsZS5jb20=\nvless://example',
      ),
      'hamid@example.com',
    );
    expect(
      parseSubscriptionAccountEmail(
        const {},
        'vless://example#hamid@example.com',
      ),
      isNull,
    );
  });

  test('reads Sanaei Email labels and base64 subscription metadata', () {
    expect(parseSubscriptionAccountEmail({'Email': 'Hamid'}, ''), 'Hamid');
    expect(parseSubscriptionAccountEmail({'Email': 'SGFtaWQ='}, ''), 'Hamid');
    final encodedBody = base64Encode(
      utf8.encode('#Email: Hamid\nvless://example'),
    );
    expect(parseSubscriptionAccountEmail(const {}, encodedBody), 'Hamid');
    expect(
      parseSubscriptionAccountEmail(const {}, 'Email: Hamid\nvless://example'),
      'Hamid',
    );
    expect(
      parseSubscriptionAccountEmail(const {}, '{"client":{"Email":"Hamid"}}'),
      'Hamid',
    );
    final encodedJson = base64Encode(
      utf8.encode('{"client":{"Email":"Hamid"}}'),
    );
    expect(parseSubscriptionAccountEmail(const {}, encodedJson), 'Hamid');
  });
}
