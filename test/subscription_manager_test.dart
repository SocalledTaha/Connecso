import 'dart:async';

import 'package:connecso_client/data/repositories/saved_subscriptions.dart';
import 'package:connecso_client/ui/settings/subscription_manager_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('lists saved subscriptions and selects an inactive profile', (
    tester,
  ) async {
    String? selected;
    final selectionGate = Completer<void>();
    await tester.pumpWidget(
      _settings(
        subscriptions: const [
          SavedSubscription(id: 'one', name: 'Work VPN'),
          SavedSubscription(id: 'two', name: 'Travel VPN'),
        ],
        activeId: 'one',
        onSelect: (id) async {
          selected = id;
          await selectionGate.future;
        },
      ),
    );

    expect(find.text('Theme'), findsNothing);
    expect(find.text('Language'), findsNothing);
    await tester.tap(find.text('Travel VPN'));
    expect(selected, 'two');
    expect(find.text('Work VPN'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    selectionGate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('renames a saved profile without a redundant sign out action', (
    tester,
  ) async {
    String? renamed;
    String? editedEndpoint;
    await tester.pumpWidget(
      _settings(
        subscriptions: const [SavedSubscription(id: 'one', name: 'Work VPN')],
        activeId: 'one',
        onRename: (id, name, endpoint, autoRefresh, interval) async {
          renamed = '$id:$name';
          editedEndpoint = endpoint;
        },
      ),
    );

    await tester.tap(find.byTooltip('Edit subscription').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Office VPN');
    await tester.enterText(
      find.byType(TextField).last,
      'https://example.com/new-subscription',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(renamed, 'one:Office VPN');
    expect(editedEndpoint, 'https://example.com/new-subscription');

    expect(find.text('Sign out'), findsNothing);
    expect(find.text('Office VPN'), findsOneWidget);
  });
}

Widget _settings({
  required List<SavedSubscription> subscriptions,
  required String? activeId,
  Future<void> Function(String) onSelect = _noopSelect,
  Future<void> Function(String, String, String?, bool, int?) onRename =
      _noopRename,
  Future<void> Function() onSignOut = _noop,
}) => MaterialApp(
  home: Scaffold(
    body: SubscriptionManagerSheet(
      language: const Locale('en'),
      savedSubscriptions: subscriptions,
      activeSubscriptionId: activeId,
      canManageSubscriptions: true,
      onSelectSubscription: onSelect,
      onEditSubscription: onRename,
      onRefreshSubscription: (_) async {},
      onDeleteSubscription: (_) async {},
      onTogglePinned: (_, _) async {},
      onSignOut: onSignOut,
      onImportClipboard: _noop,
      onScanQr: _noop,
    ),
  ),
);

Future<void> _noop() async {}
Future<void> _noopSelect(String _) async {}
Future<void> _noopRename(
  String _,
  String _,
  String? _,
  bool __,
  int? ___,
) async {}
