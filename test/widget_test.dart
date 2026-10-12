import 'package:connecso_client/domain/models/connection_state.dart';
import 'package:connecso_client/domain/services/split_tunnel_policy.dart';
import 'package:connecso_client/ui/widgets/connection_control.dart';
import 'package:connecso_client/ui/split_tunneling/split_tunneling_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('connection control exposes its status label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionControl(
            phase: ConnectionPhase.disconnected,
            label: 'Disconnected',
            actionLabel: 'Tap to connect',
            onPressed: null,
          ),
        ),
      ),
    );
    expect(find.byType(ConnectionControl), findsOneWidget);
  });

  testWidgets(
    'Split Tunneling preserves prior choices and offers Google apps',
    (tester) async {
      SplitTunnelPolicy? saved;
      var iconRequests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SplitTunnelingScreen(
            language: const Locale('en'),
            loadApplications: () async => const [
              InstalledApplication(
                packageName: 'com.example.mail',
                label: 'Mail',
                isSystemApp: false,
              ),
              InstalledApplication(
                packageName: 'com.android.settings',
                label: 'Settings',
                isSystemApp: true,
              ),
              InstalledApplication(
                packageName: 'com.google.android.apps.maps',
                label: 'Google Maps',
                isSystemApp: false,
              ),
            ],
            initialPolicy: const SplitTunnelPolicy(
              mode: SplitTunnelMode.excludeSelected,
              packageNames: {'com.example.mail'},
            ),
            loadApplicationIcon: (_) async {
              iconRequests++;
              return null;
            },
            onSave: (policy) async => saved = policy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Mail'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
      expect(find.text('Google Maps'), findsOneWidget);
      expect(iconRequests, 2);
      expect(find.text('Selected apps bypass the VPN.'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
      expect(find.text('Invert'), findsOneWidget);
      expect(find.text('Clear selected'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('split-tunnel-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show system apps'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved?.mode, SplitTunnelMode.excludeSelected);
      expect(saved?.packageNames, {'com.example.mail', 'com.android.settings'});
    },
  );

  testWidgets('bulk selection works without enabling Split Tunneling', (
    tester,
  ) async {
    SplitTunnelPolicy? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: SplitTunnelingScreen(
          language: const Locale('en'),
          loadApplications: () async => const [
            InstalledApplication(
              packageName: 'com.example.one',
              label: 'One',
              isSystemApp: false,
            ),
            InstalledApplication(
              packageName: 'com.example.two',
              label: 'Two',
              isSystemApp: false,
            ),
          ],
          initialPolicy: const SplitTunnelPolicy(
            mode: SplitTunnelMode.off,
            packageNames: {},
          ),
          onSave: (policy) async => saved = policy,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved?.mode, SplitTunnelMode.excludeSelected);
    expect(saved?.packageNames, {'com.example.one', 'com.example.two'});
  });
}
