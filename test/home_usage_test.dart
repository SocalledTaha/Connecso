import 'package:connecso_client/domain/models/connection_state.dart';
import 'package:connecso_client/domain/models/vpn_node.dart';
import 'package:connecso_client/domain/services/location_resolver.dart';
import 'package:connecso_client/domain/services/usage_service.dart';
import 'package:connecso_client/ui/home/home_screen.dart';
import 'package:connecso_client/ui/widgets/connection_control.dart';
import 'package:connecso_client/prototypes/responsive_globe.dart';
import 'package:connecso_client/ui/widgets/connection_scene.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final node = VpnNode(
    id: 'node-1',
    subscriptionId: 'sub-1',
    name: 'Germany 01',
    protocol: ProxyProtocol.vless,
    host: 'example.net',
    port: 443,
    latency: const Duration(milliseconds: 45),
    health: NodeHealth.healthy,
    lastProbe: DateTime.now(),
    successCount: 5,
    stabilityScore: 1,
  );

  Widget screen(
    Locale locale, {
    QuotaSnapshot? quotaOverride,
    ThemeMode themeMode = ThemeMode.dark,
    VpnNode? activeNodeOverride,
    Future<void> Function()? onRefreshPing,
    bool refreshingPing = false,
  }) => MaterialApp(
    locale: locale,
    theme: ThemeData.light(useMaterial3: true),
    darkTheme: ThemeData.dark(useMaterial3: true),
    themeMode: themeMode,
    home: HomeScreen(
      loading: false,
      nodes: [activeNodeOverride ?? node],
      phase: ConnectionPhase.connected,
      activeNode: activeNodeOverride ?? node,
      failure: null,
      quota:
          quotaOverride ??
          QuotaSnapshot(
            uploadBytes: 1024,
            downloadBytes: 2048,
            totalBytes: 8192,
            expiresAt: DateTime(2030, 1, 1),
          ),
      sessionUploadBytes: 500,
      sessionDownloadBytes: 1200,
      hasSubscriptionUrl: false,
      savedSubscriptions: const [],
      activeSubscriptionId: 'sub-1',
      activeSubscriptionName: 'Primary VPN',
      canManageSubscriptions: true,
      language: locale,
      themeMode: themeMode,
      destination: const DestinationLocation(
        country: 'Germany',
        countryCode: 'DE',
        city: 'Frankfurt',
        latitude: 50.1109,
        longitude: 8.6821,
        source: LocationSource.database,
        confidence: .65,
      ),
      splitTunnelingBuilder: (_) => const SizedBox.shrink(),
      onImport: (_) async {},
      onToggleConnection: () async {},
      onRefreshPing: onRefreshPing ?? () async {},
      refreshingPing: refreshingPing,
      connectionHealthReady: true,
      onLanguageChanged: (_) async {},
      onThemeChanged: (_) async {},
      onSelectSubscription: (_) async {},
      onEditSubscription: (_, _, _, _, _) async {},
      onRefreshSubscription: (_) async {},
      onDeleteSubscription: (_) async {},
      onTogglePinned: (_, _) async {},
      onSignOut: () async {},
      subscriptionRevision: ValueNotifier(0),
    ),
  );

  testWidgets('shows one composed usage card and compact subscription row', (
    tester,
  ) async {
    await tester.pumpWidget(screen(const Locale('en')));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.text('Connecso'), findsOneWidget);
    expect(find.text('Split Tunneling'), findsOneWidget);
    expect(find.text('Route selected apps separately'), findsNothing);
    expect(find.byType(ConnectionScene), findsOneWidget);
    expect(find.byType(ConnectionControl), findsOneWidget);
    expect(find.textContaining('45 ms'), findsOneWidget);
    expect(find.textContaining('Stable'), findsOneWidget);
    final mapRect = tester.getRect(find.byType(ResponsiveGlobe));
    final controlRect = tester.getRect(find.byType(ConnectionControl));
    expect(
      mapRect.width,
      closeTo(tester.view.physicalSize.width / tester.view.devicePixelRatio, 1),
    );
    final expectedMapHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(mapRect.height, closeTo(expectedMapHeight, 1));
    expect(
      controlRect.bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('unified-usage-card'))).top,
      ),
    );
    final status = tester.widget<Text>(find.text('Connected'));
    expect(status.style?.fontSize, greaterThanOrEqualTo(22));
    final metrics = tester.widget<Text>(
      find.byKey(const ValueKey('connection-metrics')),
    );
    expect(metrics.style?.fontSize, greaterThanOrEqualTo(16));
    // Check the header while its sliver is still in the viewport.
    expect(find.byTooltip('Language'), findsOneWidget);
    expect(find.byTooltip('Theme'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('unified-usage-card')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('unified-usage-card')), findsOneWidget);
    expect(find.text('This Session'), findsOneWidget);
    expect(find.text('1.7 KB'), findsOneWidget); // 500 B + 1.2 KB.
    expect(find.text('1.2 KB'), findsOneWidget);
    expect(find.text('500 B'), findsOneWidget);
    expect(find.text('Total Usage'), findsOneWidget);
    expect(find.text('3.0 KB'), findsOneWidget);
    expect(find.text('Remaining'), findsOneWidget);
    expect(find.text('5.0 KB'), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, closeTo(.375, .0001));
    expect(find.byKey(const ValueKey('session-usage-tile')), findsNothing);
    expect(find.byKey(const ValueKey('total-usage-tile')), findsNothing);
    expect(find.byKey(const ValueKey('remaining-usage-tile')), findsNothing);
    expect(find.textContaining('Subscription · Expires'), findsNothing);
    expect(find.text('Primary VPN'), findsOneWidget);
    expect(find.textContaining('Expires'), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets('quota unavailable and unlimited states do not fake progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      screen(const Locale('en'), quotaOverride: const QuotaSnapshot()),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('unified-usage-card')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Unavailable'), findsWidgets);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.pumpWidget(
      screen(
        const Locale('en'),
        quotaOverride: const QuotaSnapshot(
          uploadBytes: 100,
          downloadBytes: 100,
          totalBytes: 0,
          unlimited: true,
        ),
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('unified-usage-card')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Unlimited'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.pumpWidget(
      screen(
        const Locale('en'),
        quotaOverride: QuotaSnapshot(
          uploadBytes: 100,
          downloadBytes: 200,
          totalBytes: 1000,
          expiresAt: DateTime(2020),
        ),
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('unified-usage-card')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Expired'), findsOneWidget);
  });

  testWidgets('stale connection health is shown as unavailable', (
    tester,
  ) async {
    final staleNode = VpnNode(
      id: node.id,
      subscriptionId: node.subscriptionId,
      name: node.name,
      protocol: node.protocol,
      host: node.host,
      port: node.port,
      latency: const Duration(milliseconds: 6631),
      health: NodeHealth.healthy,
      stabilityScore: 1,
      successCount: 9,
      lastProbe: DateTime.now().subtract(const Duration(minutes: 10)),
    );
    await tester.pumpWidget(
      screen(const Locale('en'), activeNodeOverride: staleNode),
    );
    expect(find.textContaining('Ping Unavailable'), findsOneWidget);
    expect(find.textContaining('6631'), findsNothing);
    expect(find.textContaining('Stable'), findsNothing);
  });

  testWidgets('connection health tap triggers a fresh ping action', (
    tester,
  ) async {
    var refreshed = false;
    await tester.pumpWidget(
      screen(
        const Locale('en'),
        onRefreshPing: () async {
          refreshed = true;
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('refresh-connection-ping')));
    await tester.pump();
    expect(refreshed, isTrue);
  });

  testWidgets('Persian and light theme retain usage hierarchy', (tester) async {
    await tester.pumpWidget(
      screen(const Locale('fa'), themeMode: ThemeMode.light),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('این نشست'), findsOneWidget);
    expect(find.text('مصرف کل'), findsOneWidget);
    expect(find.text('باقی‌مانده'), findsOneWidget);
    expect(find.byKey(const ValueKey('unified-usage-card')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
