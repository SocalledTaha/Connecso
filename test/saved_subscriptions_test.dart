import 'package:connecso_client/data/repositories/saved_subscriptions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round trips user-owned profile names and subscription endpoints', () {
    final profile = SavedSubscription(
      id: 'sub-test_1',
      name: 'Personal VPN',
      endpoint: 'https://example.com/subscribe',
      nameCustomized: true,
      pinned: true,
      serverName: 'Connecso 🌌',
      accountEmail: 'hamid@example.com',
    );

    final decoded = SavedSubscription.fromJson(profile.toJson());

    expect(decoded.id, profile.id);
    expect(decoded.name, profile.name);
    expect(decoded.endpoint, profile.endpoint);
    expect(decoded.nameCustomized, isTrue);
    expect(decoded.pinned, isTrue);
    expect(decoded.displayName, 'Personal VPN - hamid');
    expect(decoded.serverName, 'Connecso 🌌');
  });

  test('shows fetched server title and account name together', () {
    final profile = SavedSubscription(
      id: 'sub-one',
      name: 'Subscription 1',
      serverName: 'Connecso 🌌',
      accountEmail: 'Hamid',
    );
    expect(profile.displayName, 'Connecso 🌌 - Hamid');
  });

  test('rejects invalid saved subscription identifiers and empty names', () {
    expect(
      () => SavedSubscription.fromJson({'id': '../bad', 'name': 'VPN'}),
      throwsFormatException,
    );
    expect(
      () => SavedSubscription.fromJson({'id': 'valid', 'name': '  '}),
      throwsFormatException,
    );
  });
}
