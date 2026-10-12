import 'dart:ui' as ui;

import 'package:connecso_client/domain/models/connection_state.dart';
import 'package:connecso_client/l10n/app_strings.dart';
import 'package:connecso_client/ui/widgets/connection_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('VPN exit label is localized without changing its meaning', () {
    expect(
      const AppStrings(Locale('en')).locationName('Germany', 'Frankfurt'),
      'Germany · Frankfurt',
    );
    expect(
      const AppStrings(Locale('fa')).locationName('Germany', 'Frankfurt'),
      'آلمان · فرانکفورت',
    );
    expect(
      const AppStrings(Locale('en')).locationName('Germany', ''),
      'Germany',
    );
  });

  testWidgets('Persian locale resolves RTL directionality', (tester) async {
    TextDirection? resolvedDirection;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fa'),
        supportedLocales: const [Locale('en'), Locale('fa')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (context) {
            resolvedDirection = Directionality.of(context);
            return const Scaffold();
          },
        ),
      ),
    );

    expect(resolvedDirection, TextDirection.rtl);
  });

  testWidgets('English locale resolves LTR directionality', (tester) async {
    TextDirection? resolvedDirection;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('fa')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (context) {
            resolvedDirection = Directionality.of(context);
            return const Scaffold();
          },
        ),
      ),
    );

    expect(resolvedDirection, TextDirection.ltr);
  });

  testWidgets('connection control exposes button label and action semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionControl(
            phase: ConnectionPhase.disconnected,
            label: 'Disconnected',
            actionLabel: 'Tap to connect',
            onPressed: _noop,
          ),
        ),
      ),
    );

    final node = tester.getSemantics(find.bySemanticsLabel('Disconnected'));
    expect(node.label, 'Disconnected');
    expect(node.hint, 'Tap to connect');
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isEnabled, isNot(ui.Tristate.none));
    expect(node.flagsCollection.isEnabled, ui.Tristate.isTrue);
    semantics.dispose();
  });

  testWidgets('busy connection control supports reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Scaffold(
            body: ConnectionControl(
              phase: ConnectionPhase.connecting,
              label: 'Connecting',
              actionLabel: 'Connecting to a server',
              onPressed: null,
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(ConnectionControl), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
